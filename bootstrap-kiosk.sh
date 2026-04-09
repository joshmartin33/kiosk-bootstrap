#!/usr/bin/env bash
set -euo pipefail

# Raspberry Pi Kiosk Bootstrap — V2.6 (FINAL)
# Purpose: Stable, unattended Chromium kiosk for dashboards with frequent reloads
# Hardening: Wayland-safe, keyring-free, memory-safe, refresh-safe

KIOSK_URL="${KIOSK_URL:-https://tv.zira.us}"
MIDDAY_RESTART="${MIDDAY_RESTART:-12:00:00}"
WATCHDOG_INTERVAL="${WATCHDOG_INTERVAL:-5min}"

# Prevent renderer exhaustion for 1‑minute refresh dashboards
WATCHDOG_MAX_RUNTIME_SEC=$((90 * 60))        # 90 minutes
PERIODIC_RESTART_SEC=$((75 * 60))            # 75 minutes

TARGET_USER="${TARGET_USER:-}"
USER_NAME="${TARGET_USER:-${SUDO_USER:-$(whoami)}}"

if [[ "$(id -u)" -eq 0 && -z "${SUDO_USER:-}" && -z "${TARGET_USER:-}" ]]; then
  echo "ERROR: Running as root without SUDO_USER."
  echo "Use: sudo -u <kioskuser> bash | or TARGET_USER=<kioskuser>"
  exit 1
fi

USER_HOME="$(getent passwd "$USER_NAME" | cut -d: -f6)"
SYSTEMD_DIR="$USER_HOME/.config/systemd/user"
AUTOSTART_DIR="$USER_HOME/.config/autostart"
AUTOSTART_DISABLED="$USER_HOME/.config/autostart.disabled"
BIN_DIR="$USER_HOME/bin"
KEYRING_DIR="$USER_HOME/.local/share/keyrings"

log(){ printf '%s\n' "$*"; }

as_user() { sudo -u "$USER_NAME" -H bash -lc "$*"; }

run_user_systemctl() {
  local user="$1"; shift
  local uid
  uid="$(id -u "$user")"

  sudo loginctl enable-linger "$user" >/dev/null 2>&1 || true
  sudo systemctl start "user@${uid}.service" >/dev/null 2>&1 || true

  sudo -u "$user" -H env \
    XDG_RUNTIME_DIR="/run/user/${uid}" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${uid}/bus" \
    systemctl --user "$@"
}

log "Configuring kiosk for user: $USER_NAME"
log "Dashboard URL: $KIOSK_URL"

# --- Disable legacy autostart ---
as_user "mkdir -p '$AUTOSTART_DISABLED'"
as_user "if [ -d '$AUTOSTART_DIR' ] && compgen -G '$AUTOSTART_DIR/*.desktop' >/dev/null; then mv '$AUTOSTART_DIR'/*.desktop '$AUTOSTART_DISABLED'/; fi"
as_user "mkdir -p '$AUTOSTART_DIR'"

# --- Disable GNOME Keyring ---
for f in gnome-keyring-ssh.desktop gnome-keyring-secrets.desktop gnome-keyring-pkcs11.desktop gnome-keyring-daemon.desktop; do
  as_user "cat > '$AUTOSTART_DIR/$f' <<EOF
[Desktop Entry]
Type=Application
Name=GNOME Keyring (disabled)
Hidden=true
X-GNOME-Autostart-enabled=false
EOF"
done
sudo rm -rf "$KEYRING_DIR" || true
sudo pkill -u "$USER_NAME" gnome-keyring-daemon 2>/dev/null || true

# --- Remove legacy cron kiosk logic ---
as_user "crontab -l 2>/dev/null | grep -vE '(chromium|vcgencmd|kiosk|display_power)' | crontab - 2>/dev/null || true"

# --- Ensure packages ---
if ! command -v chromium >/dev/null; then sudo apt update && sudo apt install -y chromium; fi
if ! command -v curl >/dev/null; then sudo apt update && sudo apt install -y curl; fi

as_user "mkdir -p '$SYSTEMD_DIR' '$BIN_DIR'"

# --- Chromium flags (memory‑safe for frequent reloads) ---
CHROMIUM_FLAGS="
--app=${KIOSK_URL}
--kiosk
--noerrdialogs
--disable-infobars
--disable-session-crashed-bubble
--use-gl=swiftshader
--disable-features=VizDisplayCompositor,BackForwardCache
--disable-backgrounding-occluded-windows
--disable-renderer-backgrounding
--disable-background-timer-throttling
--memory-pressure-off
--js-flags=--expose-gc
--password-store=basic
--use-mock-keychain
--disable-dev-shm-usage
"

# --- kiosk.service ---
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

# --- Watchdog: preventative runtime reset ---
as_user "cat > '$BIN_DIR/kiosk-watchdog.sh' <<EOF
#!/usr/bin/env bash
set -euo pipefail

MAX_RUNTIME=${WATCHDOG_MAX_RUNTIME_SEC}

PID=\$(pgrep -x chromium | head -n1 || true)
if [ -n \"\$PID\" ]; then
  UPTIME=\$(ps -o etimes= -p \"\$PID\" | tr -d ' ')
  if [ \"\$UPTIME\" -ge \"\$MAX_RUNTIME\" ]; then
    systemctl --user restart kiosk.service
  fi
else
  systemctl --user restart kiosk.service
fi
EOF"
as_user "chmod +x '$BIN_DIR/kiosk-watchdog.sh'"

as_user "cat > '$SYSTEMD_DIR/kiosk-watchdog.service' <<EOF
[Service]
Type=oneshot
ExecStart=%h/bin/kiosk-watchdog.sh
EOF"

as_user "cat > '$SYSTEMD_DIR/kiosk-watchdog.timer' <<EOF
[Timer]
OnBootSec=2min
OnUnitActiveSec=${WATCHDOG_INTERVAL}
[Install]
WantedBy=timers.target
EOF"

# --- Periodic renderer reset (75 min) ---
as_user "cat > '$SYSTEMD_DIR/kiosk-periodic.timer' <<EOF
[Timer]
OnBootSec=${PERIODIC_RESTART_SEC}s
OnUnitActiveSec=${PERIODIC_RESTART_SEC}s
AccuracySec=2min
[Install]
WantedBy=timers.target
EOF"

as_user "cat > '$SYSTEMD_DIR/kiosk-periodic.service' <<EOF
[Service]
Type=oneshot
ExecStart=/bin/systemctl --user restart kiosk.service
EOF"

# --- Midday restart ---
as_user "cat > '$SYSTEMD_DIR/kiosk-midday.timer' <<EOF
[Timer]
OnCalendar=*-*-* ${MIDDAY_RESTART}
Persistent=true
[Install]
WantedBy=timers.target
EOF"

as_user "cat > '$SYSTEMD_DIR/kiosk-midday.service' <<EOF
[Service]
Type=oneshot
ExecStart=/bin/systemctl --user restart kiosk.service
EOF"

# --- Enable everything ---
run_user_systemctl "$USER_NAME" daemon-reload
run_user_systemctl "$USER_NAME" enable --now \
  kiosk.service \
  kiosk-watchdog.timer \
  kiosk-periodic.timer \
  kiosk-midday.timer

log "V2.6 bootstrap complete."
