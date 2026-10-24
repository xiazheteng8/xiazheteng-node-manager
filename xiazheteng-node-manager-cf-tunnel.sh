#!/usr/bin/env bash
#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
APP="xiazheteng-node-manager"
BASE="/opt/xiazheteng-node"
BIN="$BASE/bin/xray"
CONF="$BASE/config.json"
DATA="$BASE/data"
LOGDIR="/var/log/$APP"
LOG="$LOGDIR/manager.log"
ENVFILE="$BASE/settings.env"
MANIFEST="$BASE/managed-files.txt"
SERVICE="xiazheteng-xray"
UNIT="/etc/systemd/system/$SERVICE.service"
SUB_SERVICE="xiazheteng-subscription"
SUB_UNIT="/etc/systemd/system/$SUB_SERVICE.service"
SUB_SERVER="$BASE/subscription_server.py"
SUB_TOKEN_FILE="$DATA/subscription.token"
SUB_PORT_FILE="$DATA/subscription-port.env"
SUB_URL_FILE="$DATA/subscription-url.txt"
SUBFILE="$DATA/subscription.txt"
SUBJSON="$DATA/nodes.json"
SHORTCUT="/usr/local/bin/x"
XRAY_REPO="XTLS/Xray-core"
CF_CONF="$BASE/cf-tunnel-xray.json"
CF_SERVICE="xiazheteng-cf-xray"
CF_UNIT="/etc/systemd/system/$CF_SERVICE.service"
CF_TUNNEL_SERVICE="xiazheteng-cloudflared"
CF_TUNNEL_UNIT="/etc/systemd/system/$CF_TUNNEL_SERVICE.service"
CF_TEMP_SERVICE="xiazheteng-cloudflared-temp"
CF_TEMP_UNIT="/etc/systemd/system/$CF_TEMP_SERVICE.service"
CF_TEMP_LOG="$DATA/cloudflared-temp.log"
CF_SETTINGS="$DATA/cf-tunnel-settings.env"
CF_TOKEN_FILE="$DATA/cloudflared-token.env"
CLOUDFLARED_BIN="/usr/local/bin/cloudflared"
mkdir -p "$LOGDIR"
touch "$LOG"
chmod 600 "$LOG"
log() {
    printf '[%s] [%s] %s\n' \
        "$(date '+%F %T')" "$1" "$2" | tee -a "$LOG"
}
info() { log INFO "$*"; }
warn() { log WARN "$*"; }
err()  { log ERROR "$*"; }
die()  { err "$*"; exit 1; }
trap 'rc=$?; err "命令执行失败，退出码=$rc，行号=${LINENO}。请检查 $LOG"; exit "$rc"' ERR
need_root() {
    [[ $EUID -eq 0 ]] || {
        echo "请使用 root 运行：sudo bash $0"
        exit 1
    }
}
detect_os() {
    [[ -r /etc/os-release ]] || die "无法识别操作系统。"
    . /etc/os-release
    case "${ID:-}" in
        debian|ubuntu) ;;
        *) die "当前系统 ${ID:-unknown} 不在自动部署支持列表中。" ;;
    esac
    command -v systemctl >/dev/null ||
        die "未检测到 systemd。"
    case "$(uname -m)" in
        x86_64|amd64) ARCH="64" ;;
        aarch64|arm64) ARCH="arm64-v8a" ;;
        *) die "不支持的 CPU 架构：$(uname -m)" ;;
    esac
    info "系统：${PRETTY_NAME:-$ID}，架构：$(uname -m)"
}
install_dependencies() {
    local missing=()
    for c in curl jq openssl python3 ss base64; do
        command -v "$c" >/dev/null 2>&1 || missing+=("$c")
    done
    if ((${#missing[@]})); then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -y
        apt-get install -y curl jq openssl python3 iproute2 ca-certificates
    fi
    for c in curl jq openssl python3 ss; do
        command -v "$c" >/dev/null 2>&1 ||
            die "依赖安装后仍缺少命令：$c"
    done
}
detect_public_ipv4() {
    PUBLIC_IP=""
    local ip
    for url in \
        https://api.ipify.org \
        https://ipv4.icanhazip.com \
        https://ifconfig.me/ip; do
        ip="$(curl -4 -fsS --connect-timeout 3 --max-time 6 "$url" 2>/dev/null || true)"
        if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            PUBLIC_IP="$ip"
            break
