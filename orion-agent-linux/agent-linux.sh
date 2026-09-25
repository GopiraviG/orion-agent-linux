#!/usr/bin/env bash

set +e

# ============================================================
# ORION SYSPULSE
# LINUX OBSERVABILITY AGENT
# ============================================================

HOME_DIR="${SYSPULSE_HOME:-/opt/orion/syspulse}"

CONFIG="$HOME_DIR/config.json"
LOG="$HOME_DIR/agent.log"

# ============================================================
# LOG
# ============================================================

log() {

    echo \
        "$(date '+%Y-%m-%d %H:%M:%S') $1" \
        >> "$LOG"
}

# ============================================================
# CONFIG
# ============================================================

get_config_value() {

    python3 - "$CONFIG" "$1" <<'PY'
import json
import sys

file = sys.argv[1]
key = sys.argv[2]

try:

    with open(file) as f:
        data = json.load(f)

    value = data

    for part in key.split("."):
        value = value[part]

    print(value)

except Exception:
    print("")
PY
}

SERVER_URL=$(
    get_config_value \
        "collector.endpoint"
)

TOKEN=$(
    get_config_value \
        "collector.token"
)

INTERVAL=$(
    get_config_value \
        "agent.intervalSeconds"
)

if [ -z "$INTERVAL" ]; then
    INTERVAL=60
fi

# ============================================================
# OS
# ============================================================

get_os_name() {

    if [ -f /etc/os-release ]; then

        . /etc/os-release

        echo "$PRETTY_NAME"

    else

        uname -s
    fi
}

get_os_version() {

    if [ -f /etc/os-release ]; then

        . /etc/os-release

        echo "$VERSION_ID"

    else

        uname -r
    fi
}

# ============================================================
# CPU
# ============================================================

get_cpu_usage() {

    top -bn1 2>/dev/null |
        awk '/Cpu\(s\)/ {

            print 100 - $8
            exit
        }'
}

# ============================================================
# MEMORY
# ============================================================

get_memory_json() {

    free -b 2>/dev/null |
        awk '

        NR==2 {

            total=$2
            used=$3
            free=$4

            percent=0

            if(total>0)
                percent=(used/total)*100

            printf \
            "{\"total\":\"%.2f GB\",\"used\":\"%.2f GB\",\"free\":\"%.2f GB\",\"usedPercent\":%.2f}",

            total/1024/1024/1024,
            used/1024/1024/1024,
            free/1024/1024/1024,
            percent
        }'
}

# ============================================================
# DISK
# ============================================================

get_disk_info() {

    python3 <<'PY'
import json
import subprocess

volumes = []

total_mb = 0
free_mb = 0

try:
    output = subprocess.check_output(
        ["df", "-BM", "--output=target,size,used,avail,pcent"],
        text=True
    )

    lines = output.strip().splitlines()[1:]

    for line in lines:

        parts = line.split()

        if len(parts) < 5:
            continue

        mount = parts[0]

        total = int(parts[1].replace("M",""))
        used  = int(parts[2].replace("M",""))
        free  = int(parts[3].replace("M",""))
        pct   = int(parts[4].replace("%",""))

        total_mb += total
        free_mb += free

        volumes.append({
            "Name": mount,
            "drive": mount,
            "totalMB": total,
            "freeMB": free,
            "usedMB": used,
            "usedPercent": pct
        })

except:
    pass

used_mb = total_mb - free_mb

used_percent = 0

if total_mb > 0:
    used_percent = round((used_mb/total_mb)*100,1)

print(json.dumps({
    "disk": {
        "totalMB": total_mb,
        "freeMB": free_mb,
        "usedMB": used_mb,
        "usedPercent": used_percent
    },
    "volumes": volumes
}))
PY
}
# ============================================================
# NETWORK
# ============================================================

get_ip() {

    hostname -I 2>/dev/null |
        awk '{print $1}'
}

# ============================================================
# UPTIME
# ============================================================

get_uptime_json() {

    seconds=$(cut -d. -f1 /proc/uptime)

    days=$((seconds / 86400))

    hours=$(((seconds % 86400) / 3600))

    minutes=$(((seconds % 3600) / 60))

    printf \
        '{"seconds":%d,"display":"%dd %dh %dm"}' \
        "$seconds" \
        "$days" \
        "$hours" \
        "$minutes"
}
# ============================================================
# PROCESSES
# ============================================================

get_processes_json() {

python3 <<'PY'
import json
import subprocess

processes = []

try:

    output = subprocess.check_output(
        [
            "ps",
            "-eo",
            "pid,comm,%cpu,rss",
            "--sort=-%cpu"
        ],
        text=True
    )

    for row in output.splitlines()[1:]:

        p = row.split(None, 3)

        if len(p) < 4:
            continue

        pid = int(p[0])
        name = p[1]
        cpu = float(p[2])

        mem_mb = round(
            int(p[3]) / 1024,
            2
        )

        processes.append({
            "Name": name,
            "ProcessName": name,
            "PID": pid,
            "Id": pid,
            "ProcessId": pid,
            "CPU": cpu,
            "cpuTime": cpu,
            "cpuTimeSeconds": cpu,
            "Memory": f"{mem_mb} MB",
            "WorkingSetMB": mem_mb
        })

except Exception:
    pass

top_cpu = sorted(
    processes,
    key=lambda x: x["CPU"],
    reverse=True
)[:20]

top_mem = sorted(
    processes,
    key=lambda x: x["WorkingSetMB"],
    reverse=True
)[:20]

print(json.dumps({
    "list": processes[:50],
    "topCpu": top_cpu,
    "topMemory": top_mem
}))
PY
}
# ============================================================
# USERS INFO
# ============================================================

get_users_json() {

python3 <<'PY'
import json
import getpass

print(json.dumps([
    {
        "username": getpass.getuser()
    }
]))
PY
}

# ============================================================
# System Information
# ============================================================

get_system_info() {

python3 <<'PY'
import json

vendor="-"
model="-"

try:
    vendor=open(
        "/sys/class/dmi/id/sys_vendor"
    ).read().strip()
except:
    pass

try:
    model=open(
        "/sys/class/dmi/id/product_name"
    ).read().strip()
except:
    pass

memgb=0

try:

    with open("/proc/meminfo") as f:
        for line in f:
            if line.startswith("MemTotal"):

                kb=int(line.split()[1])

                memgb=round(
                    kb/1024/1024,
                    2
                )
                break

except:
    pass

print(json.dumps({
    "manufacturer": vendor,
    "model": model,
    "domain": "-",
    "totalMemoryGB": memgb
}))
PY
}

# ============================================================
# Linux Logs
# ============================================================

get_logs_json() {

python3 <<'PY'
import json
import subprocess

logs=[]

try:

    output = subprocess.check_output(
        [
            "journalctl",
            "-n",
            "50",
            "--no-pager",
            "-o",
            "short-iso"
        ],
        text=True,
        errors="ignore"
    )

    for line in output.splitlines():

        logs.append({
            "TimeCreated":"",
            "Id":0,
            "LevelDisplayName":"Info",
            "ProviderName":"journalctl",
            "Message":str(line)
        })

except Exception:
    pass

print(json.dumps(logs, ensure_ascii=False))
PY
}
# ============================================================
# APPLICATIONS
# ============================================================

get_applications_json() {

    ps \
        -eo pid,comm \
        --sort=-%cpu \
        2>/dev/null |
        tail -n +2 |
        head -50 |
        awk '

        BEGIN {
            printf "["
        }

        {

            if(n++)
                printf ","

            printf \
                "{\"name\":%s,\"pid\":%d}",

                json($2),
                $1
        }

        END {
            printf "]"
        }

        function json(s) {

            gsub(/"/,"\\\"",s)

            return "\"" s "\""
        }'
}

# ============================================================
# SERVICES
# ============================================================

get_services_json() {

    if command -v systemctl >/dev/null 2>&1; then

        systemctl list-units \
            --type=service \
            --no-pager \
            --no-legend \
            2>/dev/null |
            head -100 |
            awk '

            BEGIN {
                printf "["
            }

            {

                if(n++)
                    printf ","

                printf \
                    "{\"name\":%s,\"status\":%s}",

                    json($1),
                    json($3)
            }

            END {
                printf "]"
            }

            function json(s) {

                gsub(/"/,"\\\"",s)

                return "\"" s "\""
            }'

    else

        echo "[]"
    fi
}

# ============================================================
# UPDATES
# ============================================================

get_patches_json() {

    if command -v apt >/dev/null 2>&1; then

        apt list --upgradable \
            2>/dev/null |
            tail -n +2 |
            head -50 |
            awk '

            BEGIN {
                printf "["
            }

            {

                if(n++)
                    printf ","

                printf \
                    "{\"id\":%s,\"description\":%s,\"installed\":\"UPDATE AVAILABLE\"}",

                    json($1),
                    json($2)
            }

            END {
                printf "]"
            }

            function json(s) {

                gsub(/"/,"\\\"",s)

                return "\"" s "\""
            }'

    elif command -v dnf >/dev/null 2>&1; then

        dnf check-update \
            2>/dev/null |
            head -50 |
            awk '

            BEGIN {
                printf "["
            }

            {
				if ($1 ~ /^[a-zA-Z0-9]/) {
			
					if(n++)
						printf ","
			
					printf \
						"{\"id\":%s,\"description\":%s,\"installed\":\"UPDATE AVAILABLE\"}",
						json($1),
						json($2)
				}
			}

            END {
                printf "]"
            }

            function json(s) {

                gsub(/"/,"\\\"",s)

                return "\"" s "\""
            }'

    else

        echo "[]"
    fi
}

# ============================================================
# COLLECT
# ============================================================

collect() {

    HOSTNAME_VALUE=$(
        hostname
    )

    OS_NAME=$(
        get_os_name
    )

    OS_VERSION=$(
        get_os_version
    )

    CPU_CORES=$(
        nproc 2>/dev/null ||
        sysctl -n hw.ncpu 2>/dev/null ||
        echo 1
    )

    CPU_USAGE=$(
        get_cpu_usage
    )

    if [ -z "$CPU_USAGE" ]; then
        CPU_USAGE=0
    fi

    MEMORY_JSON=$(
        get_memory_json
    )

    DISK_DATA=$(
        get_disk_info
    )

    UPTIME_JSON=$(
        get_uptime_json
    )

    IP=$(
        get_ip
    )

    APPLICATIONS=$(
        get_applications_json
    )

    SERVICES=$(
        get_services_json
    )

    PATCHES=$(
        get_patches_json
    )
	
	PROCESSES=$(get_processes_json)
	USERS=$(get_users_json)
	SYSTEM=$(get_system_info)
	LOGS=$(get_logs_json)
    
	
    export HOSTNAME_VALUE
    export OS_NAME
    export OS_VERSION
    export CPU_CORES
    export CPU_USAGE
    export MEMORY_JSON
    export DISK_DATA
    export UPTIME_JSON
    export IP
    export PROCESSES
    export APPLICATIONS
    export SERVICES
    export PATCHES
    export USERS
    export SYSTEM
    export LOGS

    python3 <<'PY'
import json
import os
from datetime import datetime, timezone


def json_env(name, default):
    value = os.environ.get(name, "")
    if not value:
        return default

    try:
        return json.loads(value)
    except Exception:
        return default


hostname = os.environ.get("HOSTNAME_VALUE", "")
os_name = os.environ.get("OS_NAME", "")
os_version = os.environ.get("OS_VERSION", "")

try:
    cpu_cores = int(os.environ.get("CPU_CORES", "1"))
except Exception:
    cpu_cores = 1

try:
    cpu_usage = float(os.environ.get("CPU_USAGE", "0"))
except Exception:
    cpu_usage = 0

data = {
    "schemaVersion": "1.0",

    "agent": {
        "name": "Orion SysPulse Agent",
        "version": "1.0.0"
    },

    "serverId": hostname,
    "serverName": hostname,
    "hostname": hostname,

    "username": os.environ.get("USER", ""),

    "timestamp": datetime.now(
        timezone.utc
    ).isoformat(),

    "os": {
        "name": os_name,
        "version": os_version,
        "build": "",
        "architecture": os.uname().machine
    },

    "cpu": {
        "cores": cpu_cores,
        "usagePercent": cpu_usage
    },

    "memory": json_env(
        "MEMORY_JSON",
        {}
    ),

    "disk": json_env(
        "DISK_DATA",
        {}
    ).get("disk", {}),

    "volumes": json_env(
        "DISK_DATA",
        {}
    ).get("volumes", []),

    "system": json_env(
        "SYSTEM",
        {}
    ),

    "users": json_env(
        "USERS",
        []
    ),

    "logs": json_env(
        "LOGS",
        []
    ),

    "network": {
        "ip": os.environ.get("IP", "")
    },

    "uptime": json_env(
        "UPTIME_JSON",
        {}
    ),

    "patches": json_env(
        "PATCHES",
        []
    ),

    "applications": json_env(
        "APPLICATIONS",
        []
    ),

    "processes": json_env(
        "PROCESSES",
        {}
    ),

    "services": json_env(
        "SERVICES",
        []
    )
}

print(json.dumps(data, ensure_ascii=False))
PY

}

# ============================================================
# SEND
# ============================================================

send_report() {

    if [ -z "$SERVER_URL" ]; then

        log "ERROR: collector.endpoint is empty"

        return 1
    fi

    if [ -z "$TOKEN" ]; then

        log "ERROR: collector.token is empty"

        return 1
    fi

    PAYLOAD=$(
        collect
    )

    if [ -z "$PAYLOAD" ]; then

        log "Unable to collect telemetry"

        return 1
    fi

    RESPONSE=$(
        curl \
            -sS \
            -m 30 \
            -X POST \
            -H "Content-Type: application/json" \
            -H "X-Orion-SysPulse-Token: $TOKEN" \
            --data "$PAYLOAD" \
            "$SERVER_URL" \
            2>&1
    )

    if [ $? -eq 0 ]; then

        log "Telemetry sent successfully"

        return 0

    else

        log \
            "Telemetry failed: $RESPONSE"

        return 1
    fi
}

# ============================================================
# MAIN
# ============================================================

log \
    "Orion SysPulse Linux agent started"

if [ "$1" = "--once" ]; then

    send_report

    exit $?
fi

while true; do

    send_report

    if [ "$INTERVAL" -lt 10 ]; then
        INTERVAL=60
    fi

    sleep "$INTERVAL"

done
