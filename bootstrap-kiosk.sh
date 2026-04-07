#!/usr/bin/env bash
set -euo pipefail

# Raspberry Pi Kiosk Bootstrap — V2 (Simple)
# Version: v2.1

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


KIOSK_URL="${KIOSK_URL:-https://tv.zira.us}"
MIDDAY_RESTART="12:00:00"
USER_NAME="${SUDO_USER:-$(whoami)}"

USER_HOME="$(getent passwd "$USER_NAME" | cut -d: -f6)"
SYSTEMD_DIR="$USER_HOME/.config/systemd/user"
AUTOSTART="$USER_HOME/.config/autostart"
AUTOSTART_DISABLED="$USER_HOME/.config/autostart.disabled"
BIN_DIR="$USER_HOME/bin"

as_user() { sudo -u "$USER_NAME" -H bash -lc "$*"; }

echo "Configuring kiosk for user: $USER_NAME"
echo "Kiosk URL: $KIOSK_URL"

# Disable LX autostart
as_user "mkdir -p '$AUTOSTART_DISABLED'"
as_user "if [ -d '$AUTOSTART' ]; then mv '$AUTOSTART'/*.desktop '$AUTOSTART_DISABLED'/ 2>/dev/null || true; fi"

# Remove legacy cron kiosk jobs (best effort)
as_user "crontab -l 2>/dev/null | grep -vE '(chromium|vcgencmd)' | crontab - 2>/dev/null || true"

# Ensure Chromium
if ! command -v chromium >/dev/null; then
  sudo apt update
  sudo apt install chromium -y
fi

# systemd user units
as_user "mkdir -p '$SYSTEMD_DIR' '$BIN_DIR'"

# Kiosk service
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

# Midday restart
as_user "cat > '$SYSTEMD_DIR/kiosk-midday.timer' <<EOF
[Timer]
OnCalendar=*-*-* ${MIDDAY_RESTART}
Persistent=true
[Install]
WantedBy=timers.target
EOF"

as_user "cat > '$SYSTEMD_DIR/kiosk-midday.service' <<'EOF'
[Service]
Type=oneshot
ExecStart=/bin/systemctl --user restart kiosk.service
EOF"

# Watchdog
as_user "cat > '$BIN_DIR/kiosk-watchdog.sh' <<'EOF'
#!/usr/bin/env bash
export DISPLAY=:0
if ! pgrep -x chromium >/dev/null; then
  run_user_systemctl "$USER_NAME" restart kiosk.service
fi
EOF"
as_user "chmod +x '$BIN_DIR/kiosk-watchdog.sh'"

as_user "cat > '$SYSTEMD_DIR/kiosk-watchdog.timer' <<EOF
[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
[Install]
WantedBy=timers.target
EOF"

as_user "cat > '$SYSTEMD_DIR/kiosk-watchdog.service' <<'EOF'
[Service]
Type=oneshot
ExecStart=%h/bin/kiosk-watchdog.sh
EOF"

# Enable everything
sudo loginctl enable-linger "$USER_NAME"
as_user "run_user_systemctl "$USER_NAME" daemon-reload"
as_user "run_user_systemctl "$USER_NAME" enable --now kiosk.service kiosk-midday.timer kiosk-watchdog.timer"

echo "Bootstrap complete."
``
