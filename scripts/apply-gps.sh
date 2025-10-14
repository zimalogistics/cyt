#!/usr/bin/env bash
set -euo pipefail

# Require sudo/root
if [ "$(id -u)" -ne 0 ]; then
  echo "Please run with sudo: sudo $0"
  exit 1
fi

# Locate config
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_DIR="$(cd "$SCRIPT_DIR/../config" && pwd)"
# shellcheck disable=SC1091
source "$CONF_DIR/gps.env"

# Ensure bluetooth is running (needed for rfcomm bind)
systemctl enable bluetooth >/dev/null 2>&1 || true
systemctl start bluetooth

# 1) systemd unit to bind RFCOMM on boot
UNIT_PATH="/etc/systemd/system/rfcomm-xgps150.service"
cat > "$UNIT_PATH" <<EOF
[Unit]
Description=Bind RFCOMM for XGPS150A
After=bluetooth.service
Requires=bluetooth.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/rfcomm bind ${RFCOMM_IDX} ${GPS_MAC}
ExecStop=/usr/bin/rfcomm release ${RFCOMM_IDX}

[Install]
WantedBy=multi-user.target
EOF

# 2) gpsd override to use our rfcomm device and flags
OVR_DIR="/etc/systemd/system/gpsd.service.d"
mkdir -p "$OVR_DIR"
cat > "$OVR_DIR/override.conf" <<EOF
[Service]
ExecStart=
ExecStart=/usr/sbin/gpsd ${RFCOMM_DEV} ${GPSD_FLAGS}
EOF

# 3) Install gpsd if missing
if ! command -v gpsd >/dev/null 2>&1; then
  apt-get update
  apt-get install -y gpsd gpsd-clients
fi

# 4) Enable and start services
systemctl daemon-reload
systemctl enable rfcomm-xgps150.service
systemctl restart rfcomm-xgps150.service
systemctl enable gpsd.service
systemctl restart gpsd.service

echo "✅ GPS applied. Device: ${RFCOMM_DEV} | gpsd socket: ${GPSD_SOCKET}"
echo "Test with: cgps -s"
