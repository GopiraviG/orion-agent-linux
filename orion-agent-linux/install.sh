#!/usr/bin/env bash

set -e

# ============================================================
# ORION SYSPULSE
# LINUX AGENT INSTALLER
# ============================================================

SERVER="$1"
TOKEN="$2"

if [ "$EUID" -ne 0 ]; then
    echo ""
    echo "Please run as root:"
    echo ""
    echo "  sudo ./install.sh http://SERVER-IP:5000 TOKEN"
    echo ""
    exit 1
fi

if [ -z "$SERVER" ] || [ -z "$TOKEN" ]; then

    echo ""
    echo "Usage:"
    echo ""
    echo "  sudo ./install.sh http://SERVER-IP:5000 TOKEN"
    echo ""
    exit 1
fi

SERVER="${SERVER%/}"

INSTALL_DIR="/opt/orion/syspulse"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo ""
echo "=================================================="
echo "                ORION SYSPULSE"
echo "             Linux Agent Installer"
echo "=================================================="
echo ""

echo "Collector : $SERVER"
echo "Install   : $INSTALL_DIR"
echo ""

# ============================================================
# CREATE INSTALL DIRECTORY
# ============================================================

mkdir -p "$INSTALL_DIR"

chown root:root "$INSTALL_DIR"
chmod 755 "$INSTALL_DIR"

# ============================================================
# INSTALL AGENT FILES
# ============================================================

echo "[1/4] Installing Orion SysPulse Agent..."

if [ ! -f "$SCRIPT_DIR/agent-linux.sh" ]; then

    echo ""
    echo "ERROR:"
    echo "agent-linux.sh not found."
    echo ""
    echo "Expected location:"
    echo "  $SCRIPT_DIR/agent-linux.sh"
    echo ""

    exit 1
fi

cp "$SCRIPT_DIR/agent-linux.sh" \
   "$INSTALL_DIR/agent.sh"

# fix windows line endings if present
sed -i 's/\r$//' "$INSTALL_DIR/agent.sh"

chmod 755 \
    "$INSTALL_DIR/agent.sh"

if [ -f "$SCRIPT_DIR/version.txt" ]; then

    cp "$SCRIPT_DIR/version.txt" \
       "$INSTALL_DIR/version.txt"
fi

echo "Agent installed."

# ============================================================
# CONFIGURATION
# ============================================================

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
        "users": true,
        "logs": true
    }
}
EOF

chmod 644 "$INSTALL_DIR/config.json"

echo "Configuration created."

# ============================================================
# CONNECTIVITY TEST
# ============================================================

echo "[3/4] Testing agent connectivity..."

SYSPULSE_HOME="$INSTALL_DIR" \
    "$INSTALL_DIR/agent.sh" \
    --once

echo ""
echo "Telemetry test successful."

# ============================================================
# SYSTEMD SERVICE
# ============================================================

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

User=root

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload

systemctl enable \
    orion-syspulse.service

systemctl restart \
    orion-syspulse.service

# ============================================================
# COMPLETE
# ============================================================

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