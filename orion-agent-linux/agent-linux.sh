#!/usr/bin/env bash
#
# Orion SysPulse - Linux Observability Agent
# Production-oriented, dependency-light Linux agent.
#
# Supported environments:
#   Debian/Ubuntu/Mint/Pop!_OS/Kali/Elementary and derivatives
#   RHEL/CentOS/Rocky/Alma/Fedora/Oracle Linux and derivatives
#   SUSE/SLES/openSUSE
#   Arch/Manjaro and derivatives
#   Alpine Linux
#   Generic Linux with /proc, ps, df, and optionally a package manager/systemd
#
# Runtime requirements:
#   bash, python3, curl
# Optional:
#   systemctl/journalctl, ps, free, hostname, nproc, flock
#
# The agent does NOT require root. Some host/package/log fields will be limited
# when it runs as an unprivileged user.

set -u
set -o pipefail

readonly AGENT_NAME="Orion SysPulse Agent"
readonly AGENT_VERSION="2.0.0"
readonly SCHEMA_VERSION="1.1"
readonly DEFAULT_HOME="/opt/orion/syspulse"
readonly DEFAULT_INTERVAL=60
readonly DEFAULT_HEARTBEAT_INTERVAL=5
readonly DEFAULT_HTTP_TIMEOUT=30
readonly DEFAULT_CONNECT_TIMEOUT=10
readonly DEFAULT_MAX_LOG_BYTES=$((10 * 1024 * 1024))
readonly DEFAULT_MAX_PROCESSES=50
readonly DEFAULT_TOP_PROCESSES=20
readonly DEFAULT_MAX_LOGS=100
readonly DEFAULT_MAX_PATCHES=500
readonly DEFAULT_PACKAGE_SCAN_INTERVAL=900
readonly PACKAGE_CACHE_FILE_NAME="package-cache.json"

HOME_DIR="${SYSPULSE_HOME:-$DEFAULT_HOME}"
CONFIG="$HOME_DIR/config.json"
LOG="$HOME_DIR/agent.log"
LOCK_DIR="$HOME_DIR/.agent.lock"
PID_FILE="$LOCK_DIR/pid"

SERVER_URL=""
HEARTBEAT_URL=""
TOKEN=""
INTERVAL="$DEFAULT_INTERVAL"
HEARTBEAT_INTERVAL="$DEFAULT_HEARTBEAT_INTERVAL"
HTTP_TIMEOUT="$DEFAULT_HTTP_TIMEOUT"
CONNECT_TIMEOUT="$DEFAULT_CONNECT_TIMEOUT"
MAX_PROCESSES="$DEFAULT_MAX_PROCESSES"
TOP_PROCESSES="$DEFAULT_TOP_PROCESSES"
MAX_LOGS="$DEFAULT_MAX_LOGS"
MAX_PATCHES="$DEFAULT_MAX_PATCHES"
PACKAGE_SCAN_INTERVAL="$DEFAULT_PACKAGE_SCAN_INTERVAL"
CA_BUNDLE=""
INSECURE_TLS="false"
LOG_LEVEL="INFO"
STOP_REQUESTED=0

# -----------------------------------------------------------------------------
# Logging / lifecycle
# -----------------------------------------------------------------------------

ensure_home() {
    if ! mkdir -p "$HOME_DIR" 2>/dev/null; then
        printf '%s ERROR: cannot create agent directory: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$HOME_DIR" >&2
        return 1
    fi
    return 0
}

rotate_log() {
    [ -f "$LOG" ] || return 0
    local size
    size=$(wc -c < "$LOG" 2>/dev/null || printf '0')
    if [ "$size" -ge "$DEFAULT_MAX_LOG_BYTES" ]; then
        mv -f "$LOG" "$LOG.1" 2>/dev/null || :
    fi
}

log() {
    local level="${1:-INFO}"
    shift || :
    local message="$*"
    case "$LOG_LEVEL" in
        ERROR) [ "$level" != "ERROR" ] && return 0 ;;
        WARN) [ "$level" = "INFO" ] && return 0 ;;
    esac
    ensure_home >/dev/null 2>&1 || return 0
    rotate_log
    printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$message" >> "$LOG" 2>/dev/null || :
}

fatal() {
    log ERROR "$*"
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

cleanup() {
    STOP_REQUESTED=1
    if [ -f "$PID_FILE" ]; then
        local lock_pid
        lock_pid=$(cat "$PID_FILE" 2>/dev/null || printf '')
        if [ "$lock_pid" = "$$" ]; then
            rm -f "$PID_FILE" 2>/dev/null || :
            rmdir "$LOCK_DIR" 2>/dev/null || :
        fi
    fi
}

on_signal() {
    log INFO "Shutdown requested"
    STOP_REQUESTED=1
}

trap on_signal INT TERM HUP
trap cleanup EXIT

# -----------------------------------------------------------------------------
# Single-instance lock. mkdir is atomic and does not require flock.
# -----------------------------------------------------------------------------

acquire_lock() {
    ensure_home || return 1

    if mkdir "$LOCK_DIR" 2>/dev/null; then
        printf '%s\n' "$$" > "$PID_FILE" 2>/dev/null || :
        return 0
    fi

    local old_pid=""
    [ -f "$PID_FILE" ] && old_pid=$(cat "$PID_FILE" 2>/dev/null || printf '')
    if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
        log ERROR "Another agent instance is already running (PID $old_pid)"
        return 1
    fi

    log WARN "Removing stale agent lock"
    rm -f "$PID_FILE" 2>/dev/null || :
    rmdir "$LOCK_DIR" 2>/dev/null || return 1

    if mkdir "$LOCK_DIR" 2>/dev/null; then
        printf '%s\n' "$$" > "$PID_FILE" 2>/dev/null || :
        return 0
    fi

    log ERROR "Unable to acquire agent lock"
    return 1
}

# -----------------------------------------------------------------------------
# Config
# -----------------------------------------------------------------------------

read_config() {
    [ -r "$CONFIG" ] || fatal "Configuration file not found or unreadable: $CONFIG"
    command -v python3 >/dev/null 2>&1 || fatal "python3 is required"

    # Emit tab-delimited key/value records. No eval is used, so config values
    # cannot become shell code.
    local line key value
    while IFS=$'\t' read -r key value; do
        case "$key" in
            server_url) SERVER_URL="$value" ;;
            heartbeat_url) HEARTBEAT_URL="$value" ;;
            token) TOKEN="$value" ;;
            interval) INTERVAL="$value" ;;
            heartbeat_interval) HEARTBEAT_INTERVAL="$value" ;;
            http_timeout) HTTP_TIMEOUT="$value" ;;
            connect_timeout) CONNECT_TIMEOUT="$value" ;;
            max_processes) MAX_PROCESSES="$value" ;;
            top_processes) TOP_PROCESSES="$value" ;;
            max_logs) MAX_LOGS="$value" ;;
            max_patches) MAX_PATCHES="$value" ;;
            package_scan_interval) PACKAGE_SCAN_INTERVAL="$value" ;;
            ca_bundle) CA_BUNDLE="$value" ;;
            insecure_tls) INSECURE_TLS="$value" ;;
            log_level) LOG_LEVEL="$value" ;;
        esac
    done < <(python3 - "$CONFIG" <<'PY'
import json
import sys

path = sys.argv[1]
try:
    with open(path, "r", encoding="utf-8") as f:
        cfg = json.load(f)
except Exception as exc:
    print(f"CONFIG_ERROR\t{exc}", file=sys.stderr)
    raise SystemExit(2)

def get(path, default=""):
    cur = cfg
    for key in path.split("."):
        if not isinstance(cur, dict) or key not in cur:
            return default
        cur = cur[key]
    return cur

def emit(name, path, default=""):
    value = get(path, default)
    if isinstance(value, bool):
        value = "true" if value else "false"
    elif value is None:
        value = ""
    elif isinstance(value, (dict, list)):
        value = ""
    else:
        value = str(value)
    value = value.replace("\t", " ").replace("\r", " ").replace("\n", " ")
    print(f"{name}\t{value}")

emit("server_url", "collector.endpoint")
emit("heartbeat_url", "collector.heartbeatEndpoint")
emit("token", "collector.token")
emit("interval", "agent.intervalSeconds", 60)
emit("heartbeat_interval", "agent.heartbeatIntervalSeconds", 5)
emit("http_timeout", "collector.timeoutSeconds", 30)
emit("connect_timeout", "collector.connectTimeoutSeconds", 10)
emit("max_processes", "agent.maxProcesses", 50)
emit("top_processes", "agent.topProcesses", 20)
emit("max_logs", "agent.maxLogs", 100)
emit("max_patches", "agent.maxPatches", 500)
emit("package_scan_interval", "agent.packageScanIntervalSeconds", 900)
emit("ca_bundle", "collector.caBundle", "")
emit("insecure_tls", "collector.insecureSkipVerify", False)
emit("log_level", "agent.logLevel", "INFO")
PY
    )

    # Validate numeric values. Bad config falls back to safe defaults.
    is_uint "$INTERVAL" || INTERVAL="$DEFAULT_INTERVAL"
    is_uint "$HEARTBEAT_INTERVAL" || HEARTBEAT_INTERVAL="$DEFAULT_HEARTBEAT_INTERVAL"
    is_uint "$HTTP_TIMEOUT" || HTTP_TIMEOUT="$DEFAULT_HTTP_TIMEOUT"
    is_uint "$CONNECT_TIMEOUT" || CONNECT_TIMEOUT="$DEFAULT_CONNECT_TIMEOUT"
    is_uint "$MAX_PROCESSES" || MAX_PROCESSES="$DEFAULT_MAX_PROCESSES"
    is_uint "$TOP_PROCESSES" || TOP_PROCESSES="$DEFAULT_TOP_PROCESSES"
    is_uint "$MAX_LOGS" || MAX_LOGS="$DEFAULT_MAX_LOGS"
    is_uint "$MAX_PATCHES" || MAX_PATCHES="$DEFAULT_MAX_PATCHES"
    is_uint "$PACKAGE_SCAN_INTERVAL" || PACKAGE_SCAN_INTERVAL="$DEFAULT_PACKAGE_SCAN_INTERVAL"

    # Protect the machine from pathological configuration values.
    [ "$INTERVAL" -lt 5 ] && INTERVAL=5
    [ "$HEARTBEAT_INTERVAL" -lt 1 ] && HEARTBEAT_INTERVAL=1
    [ "$HTTP_TIMEOUT" -lt 1 ] && HTTP_TIMEOUT=1
    [ "$CONNECT_TIMEOUT" -lt 1 ] && CONNECT_TIMEOUT=1
    [ "$MAX_PROCESSES" -lt 1 ] && MAX_PROCESSES=1
    [ "$MAX_PROCESSES" -gt 500 ] && MAX_PROCESSES=500
    [ "$TOP_PROCESSES" -lt 1 ] && TOP_PROCESSES=1
    [ "$TOP_PROCESSES" -gt 100 ] && TOP_PROCESSES=100
    [ "$MAX_LOGS" -lt 1 ] && MAX_LOGS=1
    [ "$MAX_LOGS" -gt 1000 ] && MAX_LOGS=1000
    [ "$MAX_PATCHES" -lt 1 ] && MAX_PATCHES=1
    [ "$MAX_PATCHES" -gt 5000 ] && MAX_PATCHES=5000
    [ "$PACKAGE_SCAN_INTERVAL" -lt 60 ] && PACKAGE_SCAN_INTERVAL=60

    case "$(printf '%s' "$LOG_LEVEL" | tr '[:lower:]' '[:upper:]')" in
        ERROR|WARN|INFO) LOG_LEVEL="$(printf '%s' "$LOG_LEVEL" | tr '[:lower:]' '[:upper:]')" ;;
        *) LOG_LEVEL="INFO" ;;
    esac

    if [ -z "$SERVER_URL" ]; then
        fatal "collector.endpoint is empty"
    fi
    if [ -z "$TOKEN" ]; then
        fatal "collector.token is empty"
    fi
    if ! command -v curl >/dev/null 2>&1; then
        fatal "curl is required"
    fi
    if [ -n "$CA_BUNDLE" ] && [ ! -r "$CA_BUNDLE" ]; then
        fatal "collector.caBundle is not readable: $CA_BUNDLE"
    fi

    if [ -z "$HEARTBEAT_URL" ]; then
        HEARTBEAT_URL=$(derive_heartbeat_url "$SERVER_URL")
    fi
}

is_uint() {
    case "${1:-}" in
        ''|*[!0-9]*) return 1 ;;
        *) return 0 ;;
    esac
}

derive_heartbeat_url() {
    python3 - "$1" <<'PY'
from urllib.parse import urlsplit, urlunsplit
import sys

url = sys.argv[1]
try:
    p = urlsplit(url)
    path = p.path or "/"
    if path.rstrip("/").endswith("/api/v1/telemetry"):
        path = path[:path.rfind("/api/v1/telemetry")] + "/api/v1/heartbeat"
    else:
        path = path.rstrip("/") + "/api/v1/heartbeat"
    print(urlunsplit((p.scheme, p.netloc, path, "", "")))
except Exception:
    print("")
PY
}

# -----------------------------------------------------------------------------
# Host / telemetry collection
# -----------------------------------------------------------------------------

collect_payload() {
    # All collection is in one Python process. This is considerably cheaper and
    # safer than starting Python once for every metric. Package inventory is
    # cached between telemetry cycles to avoid repeatedly invoking package
    # managers on production hosts.
    python3 - "$MAX_PROCESSES" "$TOP_PROCESSES" "$MAX_LOGS" "$MAX_PATCHES" "$PACKAGE_SCAN_INTERVAL" "$HOME_DIR/$PACKAGE_CACHE_FILE_NAME" <<'PY'
import gzip
import json
import os
import platform
import pwd
import re
import shutil
import socket
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

MAX_PROCESSES = max(1, int(sys.argv[1]))
TOP_PROCESSES = max(1, int(sys.argv[2]))
MAX_LOGS = max(1, int(sys.argv[3]))
MAX_PATCHES = max(1, int(sys.argv[4]))
PACKAGE_SCAN_INTERVAL = max(60, int(sys.argv[5]))
PACKAGE_CACHE_FILE = sys.argv[6]

now = time.time()


def run(cmd, timeout=5, env=None):
    try:
        p = subprocess.run(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            errors="replace",
            timeout=timeout,
            env=env,
            check=False,
        )
        return p.returncode, p.stdout
    except Exception:
        return 1, ""


def read_text(path, default=""):
    try:
        return Path(path).read_text(encoding="utf-8", errors="replace").strip()
    except Exception:
        return default


def parse_os_release():
    data = {}
    try:
        for line in Path("/etc/os-release").read_text(encoding="utf-8", errors="replace").splitlines():
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
                v = v[1:-1]
            data[k] = v
    except Exception:
        pass
    return data


def iso_utc(ts):
    try:
        return datetime.fromtimestamp(float(ts), tz=timezone.utc).isoformat()
    except Exception:
        return "-"


def number(value, default=0.0):
    try:
        return float(value)
    except Exception:
        return default


def memory_info():
    info = {}
    try:
        for line in Path("/proc/meminfo").read_text(errors="replace").splitlines():
            parts = line.split()
            if len(parts) >= 2:
                info[parts[0].rstrip(":")] = int(parts[1]) * 1024
    except Exception:
        pass
    total = info.get("MemTotal", 0)
    available = info.get("MemAvailable", info.get("MemFree", 0))
    used = max(total - available, 0)
    return {
        "totalBytes": total,
        "usedBytes": used,
        "freeBytes": max(available, 0),
        "totalGB": round(total / 1024**3, 2),
        "usedGB": round(used / 1024**3, 2),
        "freeGB": round(max(available, 0) / 1024**3, 2),
        "usedPercent": round((used / total * 100) if total else 0, 2),
    }


def cpu_usage():
    # /proc/stat gives an OS-independent Linux CPU accounting source and avoids
    # parsing locale-dependent top output. We sample for a short interval.
    def read_cpu():
        line = read_text("/proc/stat").splitlines()
        for row in line:
            if row.startswith("cpu "):
                p = row.split()
                vals = [int(x) for x in p[1:8]]
                idle = vals[3] + (vals[4] if len(vals) > 4 else 0)
                total = sum(vals)
                return total, idle
        return 0, 0
    a = read_cpu()
    time.sleep(0.15)
    b = read_cpu()
    total = b[0] - a[0]
    idle = b[1] - a[1]
    return round(max(0.0, min(100.0, (1 - idle / total) * 100)) if total else 0.0, 2)


def uptime():
    raw = read_text("/proc/uptime").split()
    try:
        seconds = int(float(raw[0]))
    except Exception:
        seconds = 0
    days, rem = divmod(seconds, 86400)
    hours, rem = divmod(rem, 3600)
    minutes = rem // 60
    return {"seconds": seconds, "display": f"{days}d {hours}h {minutes}m"}


def network_ip():
    # Prefer the address used for the host's normal outbound route. No network
    # packet is sent; UDP connect only asks the kernel for route selection.
    for family, target in ((socket.AF_INET, ("8.8.8.8", 80)), (socket.AF_INET6, ("2001:4860:4860::8888", 80, 0, 0))):
        s = socket.socket(family, socket.SOCK_DGRAM)
        try:
            s.settimeout(0.2)
            s.connect(target)
            ip = s.getsockname()[0]
            if ip and not ip.startswith("127.") and ip != "::1":
                return ip
        except Exception:
            pass
        finally:
            s.close()
    rc, out = run(["hostname", "-I"], timeout=2)
    if rc == 0:
        for ip in out.split():
            if not ip.startswith("127.") and ip != "::1":
                return ip
    return ""


def disk_info():
    mounts = []
    total = used = free = 0
    # -P ensures one filesystem per output record. Ignore pseudo filesystems and
    # inaccessible mounts to keep payloads stable on containers/servers.
    rc, out = run(["df", "-P", "-k"], timeout=10)
    if rc != 0:
        return {"disk": {"totalMB": 0, "usedMB": 0, "freeMB": 0, "usedPercent": 0}, "volumes": []}
    pseudo = ("proc", "sysfs", "tmpfs", "devtmpfs", "devpts", "cgroup", "overlay", "squashfs", "pstore", "securityfs", "debugfs", "tracefs", "configfs", "fusectl", "mqueue", "hugetlbfs", "rpc_pipefs")
    for line in out.splitlines()[1:]:
        parts = line.split()
        if len(parts) < 6:
            continue
        filesystem, size, used_s, avail, pct, mount = parts[0:6]
        if filesystem.startswith("/dev/") is False and any(filesystem.startswith(x) for x in pseudo):
            continue
        try:
            t = int(size) * 1024
            u = int(used_s) * 1024
            f = int(avail) * 1024
            p = int(pct.rstrip("%"))
        except Exception:
            continue
        total += t; used += u; free += f
        mounts.append({
            "Name": mount,
            "drive": mount,
            "totalBytes": t,
            "usedBytes": u,
            "freeBytes": f,
            "totalMB": round(t / 1024**2, 2),
            "usedMB": round(u / 1024**2, 2),
            "freeMB": round(f / 1024**2, 2),
            "usedPercent": p,
        })
    return {"disk": {"totalMB": round(total/1024**2, 2), "usedMB": round(used/1024**2, 2), "freeMB": round(free/1024**2, 2), "usedPercent": round(used/total*100, 2) if total else 0}, "volumes": mounts}


def process_info():
    processes = []
    # ps is more portable across Linux distributions than assuming /proc layout
    # details. Fields are explicit so process names containing spaces remain safe.
    commands = ["ps", "-eo", "pid=,comm=,%cpu=,rss=", "--sort=-%cpu"]
    rc, out = run(commands, timeout=10)
    if rc != 0:
        commands = ["ps", "-eo", "pid=,comm=,%cpu=,rss="]
        rc, out = run(commands, timeout=10)
    for row in out.splitlines():
        p = row.strip().split(None, 3)
        if len(p) < 4:
            continue
        try:
            pid = int(p[0]); cpu = float(p[2]); rss_kb = int(float(p[3]))
        except Exception:
            continue
        name = p[1]
        mem_mb = round(rss_kb / 1024, 2)
        processes.append({
            "Name": name,
            "ProcessName": name,
            "PID": pid,
            "Id": pid,
            "ProcessId": pid,
            "CPU": cpu,
            "cpuPercent": cpu,
            "Memory": f"{mem_mb} MB",
            "WorkingSetMB": mem_mb,
        })
        if len(processes) >= max(MAX_PROCESSES, TOP_PROCESSES):
            break
    top_cpu = sorted(processes, key=lambda x: x["CPU"], reverse=True)[:TOP_PROCESSES]
    top_mem = sorted(processes, key=lambda x: x["WorkingSetMB"], reverse=True)[:TOP_PROCESSES]
    return {"list": processes[:MAX_PROCESSES], "topCpu": top_cpu, "topMemory": top_mem}


def current_user():
    try:
        return pwd.getpwuid(os.getuid()).pw_name
    except Exception:
        return os.environ.get("USER", "")


def users_info():
    users = []
    rc, out = run(["who"], timeout=3)
    if rc == 0:
        for row in out.splitlines():
            p = row.split()
            if not p:
                continue
            item = {"username": p[0]}
            if len(p) > 1:
                item["terminal"] = p[1]
            if len(p) > 2:
                item["login"] = " ".join(p[2:])
            users.append(item)
    if not users:
        users = [{"username": current_user()}]
    return users[:100]


def system_info():
    vendor = read_text("/sys/class/dmi/id/sys_vendor", "-")
    model = read_text("/sys/class/dmi/id/product_name", "-")
    product_version = read_text("/sys/class/dmi/id/product_version", "-")
    machine = platform.machine() or "-"
    mem = memory_info()
    return {
        "manufacturer": vendor or "-",
        "model": model or "-",
        "productVersion": product_version or "-",
        "architecture": machine,
        "kernel": platform.release() or "-",
        "totalMemoryGB": mem["totalGB"],
    }


def services_info():
    services = []
    if shutil.which("systemctl"):
        rc, out = run(["systemctl", "list-units", "--type=service", "--no-pager", "--no-legend", "--plain"], timeout=10)
        if rc == 0:
            for row in out.splitlines():
                p = row.split(None, 4)
                if len(p) >= 4:
                    services.append({"name": p[0], "load": p[1], "active": p[2], "status": p[3]})
    elif shutil.which("rc-status"):
        rc, out = run(["rc-status", "-a"], timeout=5)
        if rc == 0:
            for row in out.splitlines():
                p = row.split()
                if len(p) >= 2 and not row.startswith("Runlevel:"):
                    services.append({"name": p[0], "status": p[-1]})
    return services[:200]


def classify_log(line):
    lower = line.lower()
    if re.search(r"\b(emerg|alert|crit|critical|panic|fatal)\b", lower):
        return "Critical"
    if re.search(r"\b(err|error|failed|failure)\b", lower):
        return "Error"
    if re.search(r"\b(warn|warning)\b", lower):
        return "Warning"
    return "Info"


def logs_info():
    logs = []
    if shutil.which("journalctl"):
        rc, out = run(["journalctl", "-n", str(MAX_LOGS), "--no-pager", "-o", "short-iso"], timeout=10)
        if rc == 0:
            for idx, line in enumerate(out.splitlines(), 1):
                provider = "journalctl"
                m = re.search(r"\s([\w.-]+)\[(\d+)\]:", line)
                if m:
                    provider = m.group(1)
                logs.append({"TimeCreated": line[:25] if len(line) >= 25 else "", "Id": idx, "LevelDisplayName": classify_log(line), "ProviderName": provider, "Message": line})
            return logs[-MAX_LOGS:]
    for path in ("/var/log/syslog", "/var/log/messages", "/var/log/system.log"):
        if os.path.isfile(path) and os.access(path, os.R_OK):
            try:
                with open(path, "rb") as f:
                    f.seek(0, os.SEEK_END)
                    size = f.tell()
                    f.seek(max(0, size - 1024 * 1024))
                    lines = f.read().decode("utf-8", "replace").splitlines()[-MAX_LOGS:]
                for idx, line in enumerate(lines, 1):
                    logs.append({"TimeCreated": line[:25] if len(line) >= 25 else "", "Id": idx, "LevelDisplayName": classify_log(line), "ProviderName": os.path.basename(path), "Message": line})
                return logs
            except Exception:
                pass
    return logs


def applications_info():
    # Keep this compatible with ps implementations that do not support --sort.
    rc, out = run(["ps", "-eo", "pid=,comm="], timeout=5)
    apps = []
    if rc == 0:
        seen = set()
        for row in out.splitlines():
            p = row.strip().split(None, 1)
            if len(p) != 2:
                continue
            try:
                pid = int(p[0])
            except Exception:
                continue
            name = p[1]
            if name in seen:
                continue
            seen.add(name)
            apps.append({"name": name, "pid": pid})
            if len(apps) >= 50:
                break
    return apps


def rpm_packages(limit):
    patches = []
    if not shutil.which("rpm"):
        return patches
    rc, out = run(["rpm", "-qa", "--qf", "%{NAME}\t%{VERSION}-%{RELEASE}\t%{INSTALLTIME}\n"], timeout=60)
    if rc != 0:
        return patches
    for line in out.splitlines():
        p = line.split("\t")
        if len(p) < 3:
            continue
        patches.append({"id": p[0], "description": f"{p[0]} {p[1]}", "installedOn": iso_utc(p[2]), "status": "SUCCESS"})
        if len(patches) >= limit:
            break
    return patches


def deb_packages(limit):
    patches = []
    if not shutil.which("dpkg-query"):
        return patches
    install_dates = {}
    for path in ("/var/log/dpkg.log", "/var/log/dpkg.log.1", "/var/log/dpkg.log.2.gz", "/var/log/dpkg.log.3.gz"):
        if not os.path.exists(path):
            continue
        try:
            opener = gzip.open if path.endswith(".gz") else open
            with opener(path, "rt", encoding="utf-8", errors="ignore") as f:
                for line in f:
                    m = re.match(r"^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}) install\s+([^\s:]+)", line)
                    if m:
                        install_dates[m.group(2)] = m.group(1)
        except Exception:
            pass
    rc, out = run(["dpkg-query", "-W", "-f=${Package}\t${Version}\t${Status}\n"], timeout=60)
    if rc != 0:
        return patches
    for line in out.splitlines():
        p = line.split("\t")
        if len(p) < 3 or "install ok installed" not in p[2]:
            continue
        pkg = p[0]
        base = pkg.split(":", 1)[0]
        patches.append({"id": pkg, "description": f"{pkg} {p[1]}", "installedOn": install_dates.get(pkg, install_dates.get(base, "-")), "status": "SUCCESS"})
        if len(patches) >= limit:
            break
    return patches


def arch_packages(limit):
    patches = []
    db = Path("/var/lib/pacman/local")
    if not db.is_dir():
        return patches
    for directory in sorted(db.iterdir()):
        desc = directory / "desc"
        if not desc.is_file():
            continue
        fields = {}
        field = None
        try:
            for line in desc.read_text(errors="replace").splitlines():
                if line.startswith("%"):
                    field = line
                elif line and field:
                    fields[field] = line
                    field = None
        except Exception:
            continue
        name = fields.get("%NAME%")
        if name:
            install_date = fields.get("%INSTALLDATE%", "-")
            patches.append({"id": name, "description": f"{name} {fields.get('%VERSION%', '')}".strip(), "installedOn": iso_utc(install_date) if install_date.isdigit() else install_date, "status": "SUCCESS"})
        if len(patches) >= limit:
            break
    return patches


def alpine_packages(limit):
    patches = []
    if not shutil.which("apk"):
        return patches
    rc, out = run(["apk", "info", "-v"], timeout=60)
    if rc != 0:
        return patches
    # Split at the final -rN revision. Package names may themselves contain '-'.
    rx = re.compile(r"^(.+)-([0-9][^-]*)-r([0-9]+)$")
    for line in out.splitlines():
        line = line.strip()
        if not line:
            continue
        m = rx.match(line)
        if m:
            name = m.group(1); version = f"{m.group(2)}-r{m.group(3)}"
        else:
            name = line; version = ""
        patches.append({"id": name, "description": f"{name} {version}".strip(), "installedOn": "-", "status": "SUCCESS"})
        if len(patches) >= limit:
            break
    return patches


def pending_updates(os_id, os_like, limit):
    result = []
    def add(name, version):
        if name and len(result) < limit:
            result.append({"id": name, "description": f"{name} update ({version})" if version else f"{name} update", "installedOn": "-", "status": "PENDING"})
    if os_id in {"debian", "ubuntu", "linuxmint", "mint", "pop", "elementary", "kali"} or "debian" in os_like:
        if shutil.which("apt"):
            rc, out = run(["apt", "list", "--upgradable"], timeout=30)
            if rc in (0, 100):
                for line in out.splitlines():
                    if not line or line.startswith("Listing"):
                        continue
                    p = line.split()
                    if len(p) >= 2:
                        add(p[0].split("/", 1)[0], p[1])
    elif shutil.which("dnf") and (os_id in {"rhel", "centos", "rocky", "almalinux", "fedora", "ol", "oracle"} or "rhel" in os_like or "fedora" in os_like):
        rc, out = run(["dnf", "check-update", "--quiet"], timeout=45)
        if rc in (0, 100):
            for line in out.splitlines():
                p = line.split()
                if len(p) >= 2 and "." in p[0]:
                    add(p[0], p[1])
    elif shutil.which("yum") and (os_id in {"rhel", "centos", "rocky", "almalinux", "ol", "oracle"} or "rhel" in os_like):
        rc, out = run(["yum", "check-update", "-q"], timeout=45)
        if rc in (0, 100):
            for line in out.splitlines():
                p = line.split()
                if len(p) >= 2 and "." in p[0]:
                    add(p[0], p[1])
    elif os_id in {"sles", "suse", "opensuse", "opensuse-leap", "opensuse-tumbleweed"} or "suse" in os_like:
        if shutil.which("zypper"):
            rc, out = run(["zypper", "--non-interactive", "list-updates"], timeout=45)
            if rc == 0:
                for line in out.splitlines():
                    p = line.split()
                    if len(p) >= 3 and p[0] not in {"S", "--"}:
                        add(p[1], p[-1])
    elif os_id in {"arch", "manjaro"} or "arch" in os_like:
        if shutil.which("checkupdates"):
            rc, out = run(["checkupdates"], timeout=45)
        elif shutil.which("pacman"):
            rc, out = run(["pacman", "-Qu"], timeout=45)
        else:
            rc, out = 1, ""
        if rc in (0, 2):
            for line in out.splitlines():
                p = line.split()
                if len(p) >= 2:
                    add(p[0], p[1])
    elif os_id == "alpine" and shutil.which("apk"):
        rc, out = run(["apk", "version", "-l", "<"], timeout=45)
        if rc == 0:
            for line in out.splitlines():
                p = line.split()
                if len(p) >= 2:
                    add(p[0], p[-1])
    return result


def package_info():
    osr = parse_os_release()
    os_id = osr.get("ID", "").lower()
    os_like = osr.get("ID_LIKE", "").lower()
    # Package inventory is intentionally cacheable because scanning thousands of
    # packages every 5-60 seconds is unnecessary load on production hosts.
    patches = []
    if os_id in {"debian", "ubuntu", "linuxmint", "mint", "pop", "elementary", "kali"} or "debian" in os_like:
        patches = deb_packages(MAX_PATCHES)
    elif os_id == "arch" or os_id == "manjaro" or "arch" in os_like:
        patches = arch_packages(MAX_PATCHES)
    elif os_id == "alpine":
        patches = alpine_packages(MAX_PATCHES)
    elif shutil.which("rpm"):
        patches = rpm_packages(MAX_PATCHES)
    patches.extend(pending_updates(os_id, os_like, MAX_PATCHES))
    unique = {}
    for p in patches:
        unique[(p.get("id", ""), p.get("status", ""))] = p
    result = list(unique.values())
    result.sort(key=lambda x: (0 if x.get("status") == "PENDING" else 1, x.get("id", "").lower()))
    return result[:MAX_PATCHES]


osr = parse_os_release()
os_name = osr.get("PRETTY_NAME") or osr.get("NAME") or platform.system()
os_version = osr.get("VERSION_ID") or platform.release()
arch = platform.machine() or "unknown"
hostname = socket.gethostname()

def cached_package_info():
    try:
        p = Path(PACKAGE_CACHE_FILE)
        if p.is_file() and now - p.stat().st_mtime < PACKAGE_SCAN_INTERVAL:
            data = json.loads(p.read_text(encoding="utf-8"))
            if isinstance(data, list):
                return data[:MAX_PATCHES]
    except Exception:
        pass

    patches = package_info()
    try:
        tmp = Path(PACKAGE_CACHE_FILE + ".tmp")
        tmp.write_text(json.dumps(patches, ensure_ascii=False), encoding="utf-8")
        os.replace(tmp, PACKAGE_CACHE_FILE)
    except Exception:
        pass
    return patches

patches = cached_package_info()

memory = memory_info()
disks = disk_info()

payload = {
    "schemaVersion": "1.1",
    "agent": {"name": "Orion SysPulse Agent", "version": "2.0.0"},
    "serverId": hostname,
    "serverName": hostname,
    "hostname": hostname,
    "username": current_user(),
    "timestamp": datetime.now(timezone.utc).isoformat(),
    "os": {
        "name": os_name,
        "version": os_version,
        "build": osr.get("BUILD_ID", ""),
        "id": osr.get("ID", ""),
        "architecture": arch,
    },
    "cpu": {
        "cores": os.cpu_count() or 1,
        "usagePercent": cpu_usage(),
    },
    "memory": memory,
    "disk": disks["disk"],
    "volumes": disks["volumes"],
    "system": system_info(),
    "users": users_info(),
    "logs": logs_info(),
    "network": {"ip": network_ip()},
    "uptime": uptime(),
    "patches": patches,
    "applications": applications_info(),
    "processes": process_info(),
    "services": services_info(),
}

print(json.dumps(payload, ensure_ascii=False, separators=(",", ":")))
PY
}

# -----------------------------------------------------------------------------
# HTTP
# -----------------------------------------------------------------------------

build_curl_args() {
    CURL_ARGS=(
        --silent
        --show-error
        --fail
        --location
        --connect-timeout "$CONNECT_TIMEOUT"
        --max-time "$HTTP_TIMEOUT"
        --retry 2
        --retry-delay 1
        --retry-max-time "$HTTP_TIMEOUT"
        --header 'Content-Type: application/json'
        --header "X-Orion-SysPulse-Token: $TOKEN"
    )
    if [ -n "$CA_BUNDLE" ]; then
        CURL_ARGS+=(--cacert "$CA_BUNDLE")
    elif [ "$INSECURE_TLS" = "true" ]; then
        CURL_ARGS+=(--insecure)
    fi
}

send_json() {
    local url="$1"
    local payload="$2"
    local response_file="$HOME_DIR/.http-response.$$"
    local curl_rc=0

    curl "${CURL_ARGS[@]}" \
        --data-binary "$payload" \
        --output "$response_file" \
        "$url" 2>"$HOME_DIR/.http-error.$$" || curl_rc=$?

    if [ "$curl_rc" -eq 0 ]; then
        rm -f "$response_file" "$HOME_DIR/.http-error.$$" 2>/dev/null || :
        return 0
    fi

    local err
    err=$(cat "$HOME_DIR/.http-error.$$" 2>/dev/null || printf 'HTTP request failed')
    log WARN "HTTP POST failed (exit $curl_rc): ${err:0:500}"
    rm -f "$response_file" "$HOME_DIR/.http-error.$$" 2>/dev/null || :
    return "$curl_rc"
}

send_heartbeat() {
    local hostname_value payload
    hostname_value=$(hostname 2>/dev/null || uname -n)
    payload=$(python3 - "$hostname_value" <<'PY'
import json, sys
from datetime import datetime, timezone
h = sys.argv[1]
print(json.dumps({
    "serverId": h,
    "serverName": h,
    "hostname": h,
    "timestamp": datetime.now(timezone.utc).isoformat(),
    "agent": {"name": "Orion SysPulse Agent", "version": "2.0.0"},
}))
PY
) || return 1

    if send_json "$HEARTBEAT_URL" "$payload"; then
        log INFO "Heartbeat sent"
        return 0
    fi
    return 1
}

send_report() {
    local payload
    payload=$(collect_payload) || {
        log ERROR "Telemetry collection failed"
        return 1
    }

    if [ -z "$payload" ]; then
        log ERROR "Telemetry collection returned an empty payload"
        return 1
    fi

    # Validate the generated JSON before sending it. This prevents malformed
    # telemetry from becoming a repeated network failure.
    if ! printf '%s' "$payload" | python3 -m json.tool >/dev/null 2>&1; then
        log ERROR "Telemetry collector produced invalid JSON"
        return 1
    fi

    if send_json "$SERVER_URL" "$payload"; then
        log INFO "Telemetry sent successfully"
        return 0
    fi
    return 1
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

usage() {
    cat <<USAGE
Usage: $0 [--once|--test-config|--version|--help]

  --once          Collect and send one telemetry report, then exit.
  --test-config   Validate config/dependencies without sending telemetry.
  --version       Print agent version.
  --help          Show this help.

Environment:
  SYSPULSE_HOME   Override the default agent directory ($DEFAULT_HOME).
USAGE
}

main() {
    case "${1:-}" in
        --version)
            printf '%s %s\n' "$AGENT_NAME" "$AGENT_VERSION"
            return 0
            ;;
        --help|-h)
            usage
            return 0
            ;;
    esac

    ensure_home || return 1
    acquire_lock || return 1
    read_config
    build_curl_args

    case "${1:-}" in
        --test-config)
            log INFO "Configuration validated successfully"
            printf 'Configuration OK\nEndpoint: %s\nHeartbeat: %s\nInterval: %ss\n' "$SERVER_URL" "$HEARTBEAT_URL" "$INTERVAL"
            return 0
            ;;
        --once)
            send_report
            return $?
            ;;
        "") ;;
        *) usage >&2; return 2 ;;
    esac

    log INFO "$AGENT_NAME v$AGENT_VERSION starting"
    log INFO "Telemetry interval=${INTERVAL}s heartbeat=${HEARTBEAT_INTERVAL}s packageScan=${PACKAGE_SCAN_INTERVAL}s"

    local next_report=0
    local next_heartbeat=0
    local now_ts
    while [ "$STOP_REQUESTED" -eq 0 ]; do
        now_ts=$(date +%s)

        if [ "$now_ts" -ge "$next_heartbeat" ]; then
            send_heartbeat || :
            next_heartbeat=$((now_ts + HEARTBEAT_INTERVAL))
        fi

        if [ "$now_ts" -ge "$next_report" ]; then
            send_report || :
            next_report=$((now_ts + INTERVAL))
        fi

        # Sleep in one-second increments so SIGTERM/SIGINT is handled promptly.
        sleep 1 &
        wait $! 2>/dev/null || :
    done

    log INFO "Agent stopped"
    return 0
}

main "$@"
