#!/usr/bin/env bash
set -euo pipefail

# Raspberry Pi Kiosk Bootstrap — V2 (Hardened)
# Version: v2.2
# Model: systemd --user only, no LX autostart, no cron

KIOSK_URL="${KIOSK_URL:-https://tv.zira.us}"
MIDDAY_RESTART="${MIDDAY_RESTART:-12:00:00}"
WATCHDOG_INTERVAL="${WATCHDOG_INTERVAL:-5min}"
USER_NAME="${SUDO_USER:-$(whoami)}"

USER_HOME="$(getent passwd "$USER_NAME" | cut -d: -f6)"
SYSTEMD_DIR="$USER_HOME/.config/systemd/user"
AUTOSTART_DIR="$USER_HOME/.config/autostart"
AUTOSTART_DISABLED_DIR="$USER_HOME/.config/autostart.disabled"
BIN_DIR="$USER_HOME/bin"

log(){ printf '%s\n' "$*"; }

as_user() {
  sudo -u "$USER_NAME" -H bash -lc "$*"
}

# Always run systemctl --user against the correct bus for the target user
run_user_systemctl() {
  local user="$1"; shift
  local uid
  uid="$(id -u "$user")"

  # Ensure user manager can run without GUI login
  sudo loginctl enable-linger "$user" >/dev/null 2>&1 || true
  sudo systemctl start "user@${uid}.service" >/dev/null 2>&1 || true

  sudo -u "$user" -H env \
    XDG_RUNTIME_DIR="/run/user/${uid}" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${uid}/bus" \
    systemctl --user "$@"
}

log "Configuring kiosk for user: $USER_NAME"
log "Kiosk URL: $KIOSK_URL"

# 1) Disable LX autostart (move aside)
as_user "mkdir -p '$AUTOSTART_DISABLED_DIR'"
as_user "if [ -d '$AUTOSTART_DIR' ] && compgen -G '$AUTOSTART_DIR/*.desktop' >/dev/null; then mv '$AUTOSTART_DIR'/*.desktop '$AUTOSTART_DISABLED_DIR'/; fi"

# 2) Remove legacy cron kiosk jobs (best effort, preserve unrelated cron)
as_user "crontab -l 2>/dev/null | grep -vE '(chromium|vcgencmd|--kiosk|--app=)' | crontab - 2>/dev/null || true"

# 3) Ensure Chromium
if ! command -v chromium >/dev/null 2>&1; then
  sudo apt update
  sudo apt install -y chromium
fi

# 4) Install systemd user units + scripts
as_user "mkdir -p '$SYSTEMD_DIR' '$BIN_DIR'"

# kiosk.service
as_user "cat > '$SYSTEMD_DIR/kiosk.service' <<EOF
[Unit]
Description=Chromium Kiosk
After=network-online.target graphical-session.target
Wants=network-online.target

[Service]
Environment=DISPLAY=:0
ExecStart=/usr/bin/chromium --app=${KIOSK_URL} --kiosk --noerrdialogs --disable-infobars --disable-session-crashed-bubble
Restart=always
RestartSec=3

[Install]
WantedBy=default.target
EOF"

# midday restart (timer + oneshot service)
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

# watchdog script (runs inside user manager; use systemctl --user directly)
as_user "cat > '$BIN_DIR/kiosk-watchdog.sh' <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
export DISPLAY=:0

if ! pgrep -x chromium >/dev/null 2>&1; then
  systemctl --user restart kiosk.service
fi
EOF"
as_user "chmod +x '$BIN_DIR/kiosk-watchdog.sh'"

# watchdog timer + service
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

# 5) Enable and start units (DO NOT run via as_user; use wrapper)
run_user_systemctl "$USER_NAME" daemon-reload
run_user_systemctl "$USER_NAME" enable --now kiosk.service kiosk-midday.timer kiosk-watchdog.timer

log "Bootstrap complete."
log "Verify with:"
log "  systemctl --user status kiosk.service"
log "  systemctl --user list-timers | egrep 'kiosk-midday|kiosk-watchdog'"
