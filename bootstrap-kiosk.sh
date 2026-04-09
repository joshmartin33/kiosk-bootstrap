#!/usr/bin/env bash
set -euo pipefail

# Raspberry Pi Kiosk Bootstrap — V2.7
# DBus-safe remote execution
# Works over SSH / Pi Connect
# No OS-level package modifications

KIOSK_URL="https://tv.zira.us"

WATCHDOG_INTERVAL="5min"
MAX_RUNTIME_SEC=$((90 * 60))       # 90 minutes
PERIODIC_RESTART_SEC=$((75 * 60))  # 75 minutes

TARGET_USER="${TARGET_USER:-}"
USER_NAME="${TARGET_USER:-${SUDO_USER:-$(whoami)}}"

if [[ "$(id -u)" -eq 0 && -z "${SUDO_USER:-}" && -z "${TARGET_USER:-}" ]]; then
  echo "ERROR: Running as root without TARGET_USER."
  echo "Use: TARGET_USER=<kioskuser> curl ... | sudo bash"
  exit 1
fi

USER_UID="$(id -u "$USER_NAME")"
USER_HOME="$(getent passwd "$USER_NAME" | cut -d: -f6)"
SYSTEMD_DIR="$USER_HOME/.config/systemd/user"
BIN_DIR="$USER_HOME/bin"

log(){ printf '%s\n' "$*"; }

# ------------------------------------------------------------
# DBus-safe wrapper for systemctl --user
# ------------------------------------------------------------
run_user_systemctl() {
  sudo loginctl enable-linger "$USER_NAME" >/dev/null 2>&1 || true
  sudo systemctl start "user@${USER_UID}.service" >/dev/null 2>&1 || true

  sudo -u "$USER_NAME" -H env \
    XDG_RUNTIME_DIR="/run/user/${USER_UID}" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${USER_UID}/bus" \
    systemctl --user "$@"
}

log "Applying V2.7 kiosk for user: $USER_NAME"

mkdir -p "$SYSTEMD_DIR" "$BIN_DIR"

# ------------------------------------------------------------
# systemd --user kiosk service (VALID UNIT FORMAT)
# ------------------------------------------------------------
cat > "$SYSTEMD_DIR/kiosk.service" <<EOF
[Unit]
Description=Chromium Kiosk
After=network-online.target
Wants=network-online.target

[Service]
Environment=DISPLAY=:0
ExecStart=/usr/bin/chromium --app=${KIOSK_URL} --kiosk --noerrdialogs --disable-infobars --disable-session-crashed-bubble --use-gl=swiftshader --disable-features=VizDisplayCompositor,BackForwardCache --disable-backgrounding-occluded-windows --disable-renderer-backgrounding --disable-background-timer-throttling --memory-pressure-off --js-flags=--expose-gc --password-store=basic --use-mock-keychain --disable-dev-shm-usage
Restart=always
RestartSec=3

[Install]
WantedBy=default.target
EOF

# ------------------------------------------------------------
# Watchdog (preventative restart)
# ------------------------------------------------------------
cat > "$BIN_DIR/kiosk-watchdog.sh" <<EOF
#!/usr/bin/env bash
set -e

PID=\$(pgrep -x chromium | head -n1 || true)

if [ -n "\$PID" ]; then
  UPTIME=\$(ps -o etimes= -p "\$PID" | tr -d ' ')
  if [ "\$UPTIME" -ge "$MAX_RUNTIME_SEC" ]; then
    systemctl --user restart kiosk.service
  fi
else
  systemctl --user restart kiosk.service
fi
EOF
chmod +x "$BIN_DIR/kiosk-watchdog.sh"

cat > "$SYSTEMD_DIR/kiosk-watchdog.service" <<EOF
[Service]
Type=oneshot
ExecStart=%h/bin/kiosk-watchdog.sh
EOF

cat > "$SYSTEMD_DIR/kiosk-watchdog.timer" <<EOF
[Timer]
OnBootSec=2min
OnUnitActiveSec=$WATCHDOG_INTERVAL
[Install]
WantedBy=timers.target
EOF

# ------------------------------------------------------------
# Periodic renderer hygiene restart
# ------------------------------------------------------------
cat > "$SYSTEMD_DIR/kiosk-periodic.service" <<EOF
[Service]
Type=oneshot
ExecStart=/bin/systemctl --user restart kiosk.service
EOF

cat > "$SYSTEMD_DIR/kiosk-periodic.timer" <<EOF
[Timer]
OnBootSec=${PERIODIC_RESTART_SEC}s
OnUnitActiveSec=${PERIODIC_RESTART_SEC}s
AccuracySec=2min
[Install]
WantedBy=timers.target
EOF

# ------------------------------------------------------------
# Enable everything safely
# ------------------------------------------------------------
run_user_systemctl daemon-reload
run_user_systemctl enable --now kiosk.service kiosk-watchdog.timer kiosk-periodic.timer

log "✅ V2.7 kiosk applied successfully."
