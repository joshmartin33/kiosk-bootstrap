#!/usr/bin/env bash
set -euo pipefail

# Raspberry Pi Kiosk Bootstrap — V2 (Hardened + Keyring-free)
# Version: v2.4
# Model: systemd --user only, no LX autostart, no cron, no keyring prompts

KIOSK_URL="${KIOSK_URL:-https://tv.zira.us}"
MIDDAY_RESTART="${MIDDAY_RESTART:-12:00:00}"
WATCHDOG_INTERVAL="${WATCHDOG_INTERVAL:-5min}"

# Target kiosk user:
# - If run via sudo from that user: SUDO_USER will be set
# - If run as root directly: set TARGET_USER explicitly
TARGET_USER="${TARGET_USER:-}"
USER_NAME="${TARGET_USER:-${SUDO_USER:-$(whoami)}}"

if [[ "$(id -u)" -eq 0 && -z "${SUDO_USER:-}" && -z "${TARGET_USER:-}" ]]; then
  echo "ERROR: Running as root without SUDO_USER. Set TARGET_USER=<kioskuser> and re-run."
  echo "Example: TARGET_USER=clontarfturbo1 curl -fsSL <raw-url> | sudo bash"
  exit 1
fi

USER_HOME="$(getent passwd "$USER_NAME" | cut -d: -f6)"
SYSTEMD_DIR="$USER_HOME/.config/systemd/user"
AUTOSTART_DIR="$USER_HOME/.config/autostart"
AUTOSTART_DISABLED_DIR="$USER_HOME/.config/autostart.disabled"
BIN_DIR="$USER_HOME/bin"
KEYRING_DIR="$USER_HOME/.local/share/keyrings"

log(){ printf '%s\n' "$*"; }

as_user() {
  sudo -u "$USER_NAME" -H bash -lc "$*"
}

run_user_systemctl() {
  local user="$1"; shift
  local uid
  uid="$(id -u "$user")"

  # Ensure user manager can run without GUI login
  sudo loginctl enable-linger "$user" >/dev/null 2>&1 || true
  sudo systemctl start "user@${uid}.service" >/dev/null 2>&1 || true

  # Run systemctl against the correct user bus
  sudo -u "$user" -H env \
    XDG_RUNTIME_DIR="/run/user/${uid}" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${uid}/bus" \
    systemctl --user "$@"
}

log "Configuring kiosk for user: $USER_NAME"
log "Kiosk URL: $KIOSK_URL"

# 0) Disable GNOME Keyring (prevents password prompts on autologin kiosks)
log "== Disabling GNOME Keyring autostart (user override) =="
as_user "mkdir -p '$AUTOSTART_DIR'"

for f in gnome-keyring-ssh.desktop gnome-keyring-secrets.desktop gnome-keyring-pkcs11.desktop gnome-keyring-daemon.desktop; do
  as_user "cat > '$AUTOSTART_DIR/$f' <<EOF
[Desktop Entry]
Type=Application
Name=GNOME Keyring (disabled for kiosk)
Hidden=true
X-GNOME-Autostart-enabled=false
EOF"
done

log "== Removing existing keyrings (if any) =="
sudo rm -rf "$KEYRING_DIR" || true

log "== Stopping any running keyring daemon (best-effort) =="
sudo pkill -u "$USER_NAME" gnome-keyring-daemon >/dev/null 2>&1 || true

# 1) Disable LX autostart entries (move aside)
log "== Disabling LX autostart entries =="
as_user "mkdir -p '$AUTOSTART_DISABLED_DIR'"
as_user "if [ -d '$AUTOSTART_DIR' ] && compgen -G '$AUTOSTART_DIR/*.desktop' >/dev/null; then mv '$AUTOSTART_DIR'/*.desktop '$AUTOSTART_DISABLED_DIR'/; fi"

# Re-create keyring overrides after the move (ensures they remain in autostart)
as_user "mkdir -p '$AUTOSTART_DIR'"
for f in gnome-keyring-ssh.desktop gnome-keyring-secrets.desktop gnome-keyring-pkcs11.desktop gnome-keyring-daemon.desktop; do
  as_user "cat > '$AUTOSTART_DIR/$f' <<EOF
[Desktop Entry]
Type=Application
Name=GNOME Keyring (disabled for kiosk)
Hidden=true
X-GNOME-Autostart-enabled=false
EOF"
done

# 2) Remove legacy cron kiosk jobs (best effort, preserve unrelated cron)
log "== Removing kiosk-related cron entries (best-effort) =="
as_user "crontab -l 2>/dev/null | grep -vE '(chromium|vcgencmd|--kiosk|--app=|display_power)' | crontab - 2>/dev/null || true"

# 3) Ensure Chromium installed
log "== Ensuring Chromium installed (best-effort) =="
if ! command -v chromium >/dev/null 2>&1; then
  sudo apt update
  sudo apt install -y chromium
fi

# 4) Install systemd user units + scripts
log "== Installing systemd user units =="
as_user "mkdir -p '$SYSTEMD_DIR' '$BIN_DIR'"

# Chromium flags:
# - password-store/basic + mock-keychain avoids GNOME Keyring prompts
# - disable-gpu is optional but stabilises many Wayland kiosk builds; keep enabled by default
CHROMIUM_FLAGS="--app=${KIOSK_URL} --kiosk --noerrdialogs --disable-infobars --disable-session-crashed-bubble --password-store=basic --use-mock-keychain --disable-gpu"

# kiosk.service
as_user "cat > '$SYSTEMD_DIR/kiosk.service' <<EOF
[Unit]
Description=Chromium Kiosk
After=network-online.target graphical-session.target
Wants=network-online.target

[Service]
Environment=DISPLAY=:0
ExecStart=/usr/bin/chromium ${CHROMIUM_FLAGS}
Restart=always
RestartSec=3

[Install]
WantedBy=default.target
EOF"

# Midday restart (timer + oneshot service)
as_user "cat > '$SYSTEMD_DIR/kiosk-midday.timer' <<EOF
[Unit]
Description=Restart kiosk at midday

[Timer]
OnCalendar=*-*-* ${MIDDAY_RESTART}
Persistent=true

[Install]
WantedBy=timers.target
EOF"

as_user "cat > '$SYSTEMD_DIR/kiosk-midday.service' <<'EOF'
[Unit]
Description=Restart kiosk at midday

[Service]
Type=oneshot
ExecStart=/bin/systemctl --user restart kiosk.service
EOF"

# Watchdog script (runs inside user manager; systemctl --user is valid here)
as_user "cat > '$BIN_DIR/kiosk-watchdog.sh' <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
export DISPLAY=:0

if ! pgrep -x chromium >/dev/null 2>&1; then
  systemctl --user restart kiosk.service
fi
EOF"
as_user "chmod +x '$BIN_DIR/kiosk-watchdog.sh'"

# Watchdog timer + service
as_user "cat > '$SYSTEMD_DIR/kiosk-watchdog.timer' <<EOF
[Unit]
Description=Run kiosk watchdog

[Timer]
OnBootSec=2min
OnUnitActiveSec=${WATCHDOG_INTERVAL}

[Install]
WantedBy=timers.target
EOF"

as_user "cat > '$SYSTEMD_DIR/kiosk-watchdog.service' <<'EOF'
[Unit]
Description=Kiosk watchdog

[Service]
Type=oneshot
ExecStart=%h/bin/kiosk-watchdog.sh
EOF"

# 5) Enable and start units (IMPORTANT: call wrapper directly, not via as_user)
log "== Enabling and starting kiosk units =="
run_user_systemctl "$USER_NAME" daemon-reload
run_user_systemctl "$USER_NAME" enable --now kiosk.service kiosk-midday.timer kiosk-watchdog.timer

log "Bootstrap complete."
log "Verify:"
log "  systemctl --user status kiosk.service"
log "  systemctl --user list-timers | egrep 'kiosk-midday|kiosk-watchdog'"
