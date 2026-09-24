#!/usr/bin/env bash

set -e

SERVER="$1"
TOKEN="$2"

if [ -z "$SERVER" ] || [ -z "$TOKEN" ]; then

    echo ""
    echo "Usage:"
    echo ""
    echo "sudo ./install.sh http://SERVER-IP:5000 TOKEN"
    echo ""

    exit 1
fi

SERVER="${SERVER%/}"

INSTALL_DIR="/opt/orion/syspulse"

echo ""
echo "=================================================="
echo "                ORION SYSPULSE"
echo "             Linux Agent Installer"
echo "=================================================="
echo ""

echo "Collector : $SERVER"
echo "Install   : $INSTALL_DIR"
echo ""

mkdir -p "$INSTALL_DIR"

echo "[1/4] Downloading Orion SysPulse Agent..."

curl \
    -fsSL \
    "$SERVER/agent-linux.sh" \
    -o "$INSTALL_DIR/agent.sh"

chmod +x \
    "$INSTALL_DIR/agent.sh"

echo "[2/4] Creating configuration..."

cat > "$INSTALL_DIR/config.json" <<EOF
{
    "agent": {
        "name": "Orion SysPulse Agent",
        "version": "1.0.0",
        "intervalSeconds": 60
    },

    "collector": {
        "endpoint": "$SERVER/api/v1/telemetry",
        "token": "$TOKEN"
    },

    "collectors": {
        "system": true,
        "cpu": true,
        "memory": true,
        "disk": true,
        "network": true,
        "uptime": true,
        "processes": true,
        "applications": true,
        "services": true,
        "updates": true,
        "users": true
    }
}
EOF

echo "Configuration created."

echo "[3/4] Testing agent connectivity..."

SYSPULSE_HOME="$INSTALL_DIR" \
    "$INSTALL_DIR/agent.sh" \
    --once

echo ""
echo "Telemetry test successful."

echo "[4/4] Registering systemd service..."

cat > /etc/systemd/system/orion-syspulse.service <<EOF
[Unit]
Description=Orion SysPulse Observability Agent
After=network-online.target
Wants=network-online.target

[Service]
Type=simple

Environment=SYSPULSE_HOME=$INSTALL_DIR

ExecStart=$INSTALL_DIR/agent.sh

Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload

systemctl enable \
    orion-syspulse.service

systemctl restart \
    orion-syspulse.service

echo ""
echo "=================================================="
echo "        Orion SysPulse Agent Installed"
echo "=================================================="
echo ""

echo "Agent  : $INSTALL_DIR/agent.sh"
echo "Config : $INSTALL_DIR/config.json"
echo "Log    : $INSTALL_DIR/agent.log"

echo ""

echo "Service:"
echo "  systemctl status orion-syspulse"

echo ""

echo "Collector:"
echo "  $SERVER/api/v1/telemetry"

echo ""
echo "Agent is running."
echo ""
