#!/usr/bin/env bash

set -e

SERVICE_NAME="orion-syspulse"
INSTALL_DIR="/opt/orion/syspulse"
SERVICE_FILE="/etc/systemd/system/orion-syspulse.service"

usage() {

    echo ""
    echo "Orion SysPulse Service Manager"
    echo ""
    echo "Usage:"
    echo "  sudo ./orion.sh stop"
    echo "  sudo ./orion.sh disable"
    echo "  sudo ./orion.sh remove"
    echo ""
}

require_root() {

    if [ "$EUID" -ne 0 ]; then
        echo ""
        echo "Please run as root:"
        echo "  sudo $0"
        echo ""
        exit 1
    fi
}

stop_service() {

    echo ""
    echo "Stopping Orion SysPulse..."

    if systemctl list-unit-files | grep -q "^${SERVICE_NAME}"; then

        systemctl stop "$SERVICE_NAME" || true

        echo "Service stopped."

    else

        echo "Service not installed."

    fi
}

disable_service() {

    echo ""
    echo "Disabling Orion SysPulse..."

    if systemctl list-unit-files | grep -q "^${SERVICE_NAME}"; then

        systemctl stop "$SERVICE_NAME" || true

        systemctl disable "$SERVICE_NAME" || true

        echo "Service disabled."

    else

        echo "Service not installed."

    fi
}

remove_agent() {

    echo ""
    echo "Removing Orion SysPulse..."

    systemctl stop "$SERVICE_NAME" 2>/dev/null || true

    systemctl disable "$SERVICE_NAME" 2>/dev/null || true

    rm -f "$SERVICE_FILE"

    systemctl daemon-reload

    systemctl reset-failed

    echo "Removing installation files..."

	rm -f /usr/bin/orion
	
	rm -rf "$INSTALL_DIR"

    echo "Removing temporary installation folders..."

    rm -rf /opt/orion-install
    rm -rf /tmp/orion-install
    rm -rf /tmp/orion-agent-linux
    rm -f /tmp/orion-agent-linux.tar.gz

    echo "Searching for Orion SysPulse files..."

    find /etc -iname '*orion*' -type f -delete 2>/dev/null || true
    find /var/tmp -iname '*orion*' -delete 2>/dev/null || true

    echo ""
    echo "Orion SysPulse removed successfully."
    echo ""
}

require_root

case "$1" in

    stop)
        stop_service
        ;;

    disable)
        disable_service
        ;;

    remove)
        remove_agent
        ;;

    *)
        usage
        exit 1
        ;;
esac
``