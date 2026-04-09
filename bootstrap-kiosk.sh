#!/usr/bin/env bash
set -euo pipefail

# Raspberry Pi Kiosk Bootstrap — V2.6.1 (Corrected)
# Safe for retrofitting running devices
# Supports high-frequency dashboard refresh workloads

KIOSK_URL="https://tv.zira.us"

# Restart strategy (proven to prevent white screens)
WATCHDOG_INTERVAL="5min"
MAX_RUNTIME_SEC=$((90 * 60))       # 90 minutes
PERIODIC_RESTART_SEC=$((75 * 60))  # 75 minutes

USER_NAME="${SUDO_USER:-$(whoami)}"
USER_HOME="$(getent passwd "$USER_NAME" | cut -d: -f6)"
SYSTEMD_DIR="$USER_HOME/.config/systemd/user"
BIN_DIR="$USER_HOME/bin"

log(){ printf '%s\n' "$*"; }

log "Applying V2.6.1 kiosk for user: $USER_NAME"

mkdir -p "$SYSTEMD_DIR" "$BIN_DIR"

# -----------------------------
# systemd user kiosk.service
# -----------------------------
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

# -----------------------------
# Watchdog (preventative)
# -----------------------------
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

# -----------------------------
# Periodic renderer hygiene
# -----------------------------
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

# -----------------------------
# Enable services
# -----------------------------
systemctl --user daemon-reload
systemctl --user enable --now kiosk.service kiosk-watchdog.timer kiosk-periodic.timer

log "V2.6.1 kiosk applied."
