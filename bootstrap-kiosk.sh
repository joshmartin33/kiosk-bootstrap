#!/usr/bin/env bash
set -euo pipefail

# Raspberry Pi Kiosk Bootstrap — V2.5
# Hardened + Keyring-free + Health watchdog (Aw, Snap/chrome-error detection)
# Repo: https://github.com/joshmartin33/kiosk-bootstrap

KIOSK_URL="${KIOSK_URL:-https://tv.zira.us}"
MIDDAY_RESTART="${MIDDAY_RESTART:-12:00:00}"
WATCHDOG_INTERVAL="${WATCHDOG_INTERVAL:-5min}"
WATCHDOG_MAX_FAILS="${WATCHDOG_MAX_FAILS:-3}"

# DevTools endpoint (local only) used for health detection
DEVTOOLS_ADDR="127.0.0.1"
DEVTOOLS_PORT="9222"

# Target kiosk user:
TARGET_USER="${TARGET_USER:-}"
USER_NAME="${TARGET_USER:-${SUDO_USER:-$(whoami)}}"

if [[ "$(id -u)" -eq 0 && -z "${SUDO_USER:-}" && -z "${TARGET_USER:-}" ]]; then
  echo "ERROR: Running as root without SUDO_USER. Set TARGET_USER=<kioskuser> and re-run."
  echo "Example: curl -fsSL <raw-url> | sudo TARGET_USER=clontarfturbo1 bash"
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

  sudo loginctl enable-linger "$user" >/dev/null 2>&1 || true
  sudo systemctl start "user@${uid}.service" >/dev/null 2>&1 || true

  sudo -u "$user" -H env \
    XDG_RUNTIME_DIR="/run/user/${uid}" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${uid}/bus" \
    systemctl --user "$@"
}

log "Configuring kiosk for user: $USER_NAME"
log "Kiosk URL: $KIOSK_URL"

# 0) Disable LX autostart entries (move aside)
log "== Disabling LX autostart entries =="
as_user "mkdir -p '$AUTOSTART_DISABLED_DIR'"
as_user "if [ -d '$AUTOSTART_DIR' ] && compgen -G '$AUTOSTART_DIR/*.desktop' >/dev/null; then mv '$AUTOSTART_DIR'/*.desktop '$AUTOSTART_DISABLED_DIR'/; fi"
as_user "mkdir -p '$AUTOSTART_DIR'"

# 1) Disable GNOME Keyring (prevents password prompts on autologin kiosks)
log "== Disabling GNOME Keyring autostart (user override) =="
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

# 2) Remove legacy cron kiosk jobs (best effort, preserve unrelated cron)
log "== Removing kiosk-related cron entries (best-effort) =="
as_user "crontab -l 2>/dev/null | grep -vE '(chromium|vcgencmd|--kiosk|--app=|display_power)' | crontab - 2>/dev/null || true"

# 3) Ensure required packages
log "== Ensuring required packages installed (best-effort) =="
if ! command -v chromium >/dev/null 2>&1; then
  sudo apt update
  sudo apt install -y chromium
fi

# curl is used by watchdog for health checks
if ! command -v curl >/dev/null 2>&1; then
  sudo apt update
  sudo apt install -y curl
fi

# 4) Install systemd user units + scripts
log "== Installing systemd user units =="
as_user "mkdir -p '$SYSTEMD_DIR' '$BIN_DIR'"

# Wayland-stable Chromium flags:
# - swiftshader + disable Viz compositor reduces black/blank surface issues on Pi/Wayland
# - password-store basic + mock keychain avoids keyring prompts
# - devtools local endpoint enables watchdog to detect chrome-error/Aw Snap state
CHROMIUM_FLAGS="--app=${KIOSK_URL} --kiosk --noerrdialogs --disable-infobars --disable-session-crashed-bubble \
--use-gl=swiftshader --disable-features=VizDisplayCompositor \
--password-store=basic --use-mock-keychain \
--remote-debugging-address=${DEVTOOLS_ADDR} --remote-debugging-port=${DEVTOOLS_PORT} \
--disable-dev-shm-usage"

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

# Watchdog script — application-aware
# Detects:
# - chromium not running
# - devtools unavailable (often renderer crash/loop)
# - chrome-error:// pages
# - "Aw, Snap" title
# Also uses a consecutive failure counter to avoid restart storms.
as_user "cat > '$BIN_DIR/kiosk-watchdog.sh' <<EOF
#!/usr/bin/env bash
set -euo pipefail

URL=\"${KIOSK_URL}\"
DEVTOOLS_URL=\"http://${DEVTOOLS_ADDR}:${DEVTOOLS_PORT}/json/list\"
FAILCOUNT_FILE=\"\$HOME/.kiosk_watchdog_failures\"
MAX_FAILS=\"${WATCHDOG_MAX_FAILS}\"

log() { echo \"[kiosk-watchdog] \$*\"; }

# init counter
[ -f \"\$FAILCOUNT_FILE\" ] || echo 0 > \"\$FAILCOUNT_FILE\"
FAILS=\$(cat \"\$FAILCOUNT_FILE\" 2>/dev/null || echo 0)

# If Chromium isn't running, restart immediately
if ! pgrep -x chromium >/dev/null 2>&1; then
  log \"chromium not running -> restarting kiosk.service\"
  systemctl --user restart kiosk.service
  echo 0 > \"\$FAILCOUNT_FILE\"
  exit 0
fi

# Try DevTools health check (best signal)
JSON=\"\$(curl -fsS --max-time 2 \"\$DEVTOOLS_URL\" 2>/dev/null || true)\"

if [ -n \"\$JSON\" ]; then
  # Detect chrome internal error pages or Aw, Snap title
  if echo \"\$JSON\" | grep -q '\"url\": \"chrome-error://'; then
    log \"Detected chrome-error:// page -> restarting kiosk.service\"
    systemctl --user restart kiosk.service
    echo 0 > \"\$FAILCOUNT_FILE\"
    exit 0
  fi

  if echo \"\$JSON\" | grep -qi '\"title\": \"Aw, Snap'; then
    log \"Detected Aw, Snap -> restarting kiosk.service\"
    systemctl --user restart kiosk.service
    echo 0 > \"\$FAILCOUNT_FILE\"
    exit 0
  fi

  # If DevTools reports the main URL is not present at all, count as a failure
  if ! echo \"\$JSON\" | grep -q \"\\\"url\\\": \\\"\\\$URL\\\"\"; then
    FAILS=\$((FAILS + 1))
    echo \"\$FAILS\" > \"\$FAILCOUNT_FILE\"
    log \"DevTools reachable but expected URL not present (fails=\$FAILS)\"
  else
    # Healthy
    echo 0 > \"\$FAILCOUNT_FILE\"
    exit 0
  fi
else
  # DevTools unreachable: treat as failure (renderer crash/loop often causes this)
  FAILS=\$((FAILS + 1))
  echo \"\$FAILS\" > \"\$FAILCOUNT_FILE\"
  log \"DevTools not reachable (fails=\$FAILS)\"
fi

# Secondary check: can we reach the site at all?
if ! curl -fsS --max-time 6 \"\$URL\" >/dev/null 2>&1; then
  FAILS=\$((FAILS + 1))
  echo \"\$FAILS\" > \"\$FAILCOUNT_FILE\"
  log \"HTTP check failed (fails=\$FAILS)\"
fi

# Restart if failures exceed threshold
if [ \"\$FAILS\" -ge \"\$MAX_FAILS\" ]; then
  log \"Failure threshold reached -> restarting kiosk.service\"
  systemctl --user restart kiosk.service
  echo 0 > \"\$FAILCOUNT_FILE\"
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

# 5) Enable and start units
log "== Enabling and starting kiosk units =="
run_user_systemctl "$USER_NAME" daemon-reload
run_user_systemctl "$USER_NAME" enable --now kiosk.service kiosk-midday.timer kiosk-watchdog.timer

log "Bootstrap complete."
log "Verify:"
log "  systemctl --user status kiosk.service"
log "  systemctl --user list-timers | egrep 'kiosk-midday|kiosk-watchdog'"
