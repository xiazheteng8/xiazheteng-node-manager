
#!/usr/bin/env bash
# ============================================================
# 瞎折腾吧 | VPS 节点管理器（3x-ui API 最终修复版）
# Ubuntu / Debian
# VLESS REALITY + VLESS TLS + VMess TCP + Shadowsocks
# 自动检测、故障隔离、订阅检查、TLS 证书管理
# ============================================================

set -uo pipefail
umask 077

APP="xiazheteng-node-manager"
BASE="/opt/$APP"
DATA="$BASE/data"
ENV_FILE="$BASE/config.env"
COOKIE="$BASE/cookie.txt"
API_ROOT_FILE="$BASE/api-root"
TOKEN_FILE="$BASE/subscription.token"
RESULT_FILE="$BASE/deploy-results.txt"
LOG="/var/log/$APP.log"
SERVICE="xiazheteng-subscription"
SUB_PORT=18888
API_LAST_RESPONSE=""
API_RESPONSE_FILE="$BASE/last-api-response.json"

mkdir -p "$BASE" "$DATA" /var/log
touch "$LOG"
chmod 600 "$LOG"

log() {
    printf '[%s] %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG"
}

fail() {
    log "[失败] $*"
    return 1
}

pause() {
    read -r -p "按回车继续..." _ </dev/tty || true
}

need_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "[错误] 请使用 root 运行。"
        return 1
    fi
}

# ------------------------------------------------------------
# 基础工具
# ------------------------------------------------------------

install_dependencies() {
    export DEBIAN_FRONTEND=noninteractive

    log "[检查] 安装必要依赖。"

    apt-get update || {
        fail "apt-get update 失败，请检查系统软件源和网络。"
        return 1
    }

    apt-get install -y \
        curl ca-certificates jq openssl python3 iproute2 \
        uuid-runtime coreutils util-linux dnsutils certbot \
        python3-certbot-nginx || {
        fail "依赖安装失败。"
        return 1
    }

    local cmd
    for cmd in curl jq openssl python3 ss awk grep sed base64 certbot; do
        command -v "$cmd" >/dev/null 2>&1 || {
            fail "缺少必要命令：$cmd"
            return 1
        }
    done

    log "[成功] 依赖检查通过。"
}

get_public_ip() {
    local ip url

    for url in \
        https://api.ipify.org \
        https://ipv4.icanhazip.com \
        https://ifconfig.me/ip; do

        ip="$(curl -4 -fsS --connect-timeout 4 --max-time 8 \
            "$url" 2>/dev/null | tr -d '[:space:]' || true)"

        if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
            printf '%s\n' "$ip"
