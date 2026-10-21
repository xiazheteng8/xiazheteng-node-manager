
#!/usr/bin/env bash
# ============================================================
# 瞎折腾吧 | VPS 节点管理器
# Script: xiazheteng-node-manager.sh
# GitHub: https://github.com/xiazheteng8/xiazheteng-node-manager
# YouTube: https://www.youtube.com/@xiazheteng8
# Telegram: https://t.me/xiazheteng8
#
# 默认不使用域名。
# 域名订阅仅在用户主动选择并通过检查后启用。
# ============================================================

set -Eeuo pipefail
umask 077

APP_NAME="xiazheteng-node-manager"
SCRIPT_NAME="xiazheteng-node-manager.sh"
GITHUB_RAW="https://raw.githubusercontent.com/xiazheteng8/xiazheteng-node-manager/main/xiazheteng-node-manager.sh"
UPSTREAM_URL="https://raw.githubusercontent.com/yonggekkk/sing-box-yg/main/sb.sh"

BASE_DIR="/etc/${APP_NAME}"
CONFIG_DIR="${BASE_DIR}/config"
DATA_DIR="${BASE_DIR}/data"
BACKUP_DIR="${BASE_DIR}/backups"
LOG_DIR="/var/log/${APP_NAME}"
XRAY_CONFIG="${CONFIG_DIR}/xray.json"
NODE_FILE="${DATA_DIR}/node.txt"
SUB_FILE="${DATA_DIR}/subscribe.txt"
TOKEN_FILE="${DATA_DIR}/token"
DOMAIN_FILE="${DATA_DIR}/domain"
MODE_FILE="${DATA_DIR}/mode"
UPSTREAM_FILE="/opt/${APP_NAME}/upstream/sb.sh"

XRAY_BIN="/usr/local/bin/xray"
SERVICE_NAME="xiazheteng-node-manager.service"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}"
NGINX_SITE="/etc/nginx/conf.d/${APP_NAME}.conf"
WEB_ROOT="/var/www/${APP_NAME}"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
RESET='\033[0m'

info() { echo -e "${BLUE}[信息]${RESET} $*"; }
ok()   { echo -e "${GREEN}[成功]${RESET} $*"; }
warn() { echo -e "${YELLOW}[注意]${RESET} $*"; }
err()  { echo -e "${RED}[错误]${RESET} $*" >&2; }

pause() {
    echo
    read -r -p "按回车键继续..." _
}

require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        err "请使用 root 用户运行。"
        exit 1
    fi
}

has_cmd() {
    command -v "$1" >/dev/null 2>&1
}

detect_os() {
    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        OS_ID="${ID:-unknown}"
        OS_VERSION="${VERSION_ID:-unknown}"
    else
        OS_ID="unknown"
        OS_VERSION="unknown"
    fi
}

install_packages() {
    detect_os
    info "正在检查系统依赖..."

    if has_cmd apt-get; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -y
        apt-get install -y curl ca-certificates openssl python3
    elif has_cmd dnf; then
        dnf install -y curl ca-certificates openssl python3
    elif has_cmd yum; then
        yum install -y curl ca-certificates openssl python3
    elif has_cmd apk; then
        apk add --no-cache curl ca-certificates openssl python3
    else
        err "未识别的包管理器，请先安装 curl、openssl、python3。"
        return 1
    fi
}

ensure_dirs() {
    install -d -m 700 "$BASE_DIR" "$CONFIG_DIR" "$DATA_DIR" \
        "$BACKUP_DIR" "$LOG_DIR"
}

random_port() {
    python3 - <<'PY'
import secrets
print(secrets.randbelow(40000) + 20000)
PY
}

port_in_use() {
    local port="$1"

    if has_cmd ss; then
        ss -H -lntu 2>/dev/null |
            awk '{print $5}' |
            grep -Eq "[:.]${port}$"
    elif has_cmd netstat; then
        netstat -lntu 2>/dev/null |
            awk '{print $4}' |
            grep -Eq "[:.]${port}$"
    else
        return 1
    fi
}

choose_free_port() {
    local attempt port
    for attempt in $(seq 1 100); do
        port="$(random_port)"
        if ! port_in_use "$port"; then
            echo "$port"
            return 0
        fi
    done

    err "无法找到可用端口。"
    return 1
}

get_public_ip() {
    local ip=""
    ip="$(curl -4 -fsS --max-time 8 https://api.ipify.org 2>/dev/null || true)"
    if [[ -z "$ip" ]]; then
        ip="$(curl -4 -fsS --max-time 8 https://ifconfig.me/ip 2>/dev/null || true)"
    fi
    printf '%s' "$ip"
}

install_xray() {
    if [[ -x "$XRAY_BIN" ]]; then
        info "检测到现有 Xray：$("$XRAY_BIN" version 2>/dev/null | head -n 1 || true)"
        return 0
    fi

    info "正在安装 Xray..."
    local installer
    installer="$(mktemp)"
    if ! curl -fL --retry 3 --connect-timeout 10 \
        "https://github.com/XTLS/Xray-install/raw/main/install-release.sh" \
        -o "$installer"; then
        rm -f "$installer"
        err "下载 Xray 安装脚本失败。"
        return 1
    fi

    if ! bash "$installer" install; then
        rm -f "$installer"
        err "Xray 安装失败。"
        return 1
    fi
    rm -f "$installer"

    [[ -x "$XRAY_BIN" ]] || {
        err "未找到 Xray 可执行文件：$XRAY_BIN"
        return 1
    }
}

generate_reality_keys() {
    local output private_key public_key
    output="$("$XRAY_BIN" x25519 2>&1)" || {
        err "Xray 生成 REALITY 密钥失败：$output"
        return 1
    }

    private_key="$(printf '%s\n' "$output" |
        sed -nE 's/^(PrivateKey|Private key):[[:space:]]*//p' |
        head -n 1)"
    public_key="$(printf '%s\n' "$output" |
        sed -nE 's/^(Password|PublicKey|Public key):[[:space:]]*//p' |
        head -n 1)"

    if [[ -z "$private_key" || -z "$public_key" ]]; then
        # 兼容部分 Xray 版本的不同输出格式
        private_key="$(printf '%s\n' "$output" |
            awk -F': *' 'tolower($1) ~ /privatekey|private key/ {print $2; exit}')"
        public_key="$(printf '%s\n' "$output" |
            awk -F': *' 'tolower($1) ~ /password|publickey|public key/ {print $2; exit}')"
    fi

    if [[ -z "$private_key" || -z "$public_key" ]]; then
        err "无法识别当前 Xray 的 x25519 输出格式。"
        printf '%s\n' "$output"
        return 1
    fi

    printf '%s\n%s\n' "$private_key" "$public_key"
}

make_vless_uri() {
    local uuid="$1" address="$2" port="$3" public_key="$4" short_id="$5" name="$6"
    python3 - "$uuid" "$address" "$port" "$public_key" "$short_id" "$name" <<'PY'
import sys
from urllib.parse import quote
uuid, address, port, key, sid, name = sys.argv[1:]
if ":" in address and not address.startswith("["):
    address = "[" + address + "]"
name = quote(name, safe="")
print(
    f"vless://{uuid}@{address}:{port}"
    f"?encryption=none&security=reality&sni=www.microsoft.com"
    f"&fp=chrome&pbk={key}&sid={sid}&type=tcp"
    f"# {name}".replace(" ", "%20")
)
PY
}

write_xray_config() {
    local uuid="$1" port="$2" private_key="$3" short_id="$4"

    python3 - "$XRAY_CONFIG" "$uuid" "$port" "$private_key" "$short_id" <<'PY'
import json, sys
path, uuid, port, private_key, short_id = sys.argv[1:]
config = {
  "log": {"loglevel": "warning"},
  "inbounds": [{
    "listen": "0.0.0.0",
    "port": int(port),
    "protocol": "vless",
    "settings": {
      "clients": [{"id": uuid, "flow": "xtls-rprx-vision"}],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "tcp",
      "security": "reality",
      "realitySettings": {
        "show": False,
        "dest": "www.microsoft.com:443",
        "xver": 0,
        "serverNames": ["www.microsoft.com"],
        "privateKey": private_key,
        "shortIds": [short_id]
      }
    },
    "sniffing": {
      "enabled": True,
      "destOverride": ["http", "tls", "quic"]
    }
  }],
  "outbounds": [
    {"protocol": "freedom", "tag": "direct"},
    {"protocol": "blackhole", "tag": "block"}
  ]
}
with open(path, "w", encoding="utf-8") as f:
    json.dump(config, f, indent=2)
    f.write("\n")
PY
    chmod 600 "$XRAY_CONFIG"
}

write_service() {
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Xiazheteng Node Manager Xray Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${XRAY_BIN} run -config ${XRAY_CONFIG}
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME" >/dev/null
}

check_xray_config() {
    "$XRAY_BIN" run -test -config "$XRAY_CONFIG"
}

encode_subscription() {
    local node="$1"
    printf '%s\n' "$node" | base64 -w 0 > "$SUB_FILE"
    printf '\n' >> "$SUB_FILE"
    chmod 600 "$SUB_FILE"
}

install_certbot() {
    if has_cmd certbot; then
        return 0
    fi

    if has_cmd apt-get; then
        apt-get install -y certbot python3-certbot-nginx
    elif has_cmd dnf; then
        dnf install -y certbot python3-certbot-nginx || dnf install -y certbot
    elif has_cmd yum; then
        yum install -y certbot python3-certbot-nginx || yum install -y certbot
    else
        err "请手动安装 Certbot 及 Nginx 插件。"
        return 1
    fi
}

setup_domain_subscription() {
    local domain="$1" token

    if [[ ! "$domain" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,}$ ]]; then
        err "域名格式不正确。"
        return 1
    fi

    if ! has_cmd nginx; then
        warn "未检测到 Nginx，尝试安装..."
        if has_cmd apt-get; then
            apt-get install -y nginx
        elif has_cmd dnf; then
            dnf install -y nginx
        elif has_cmd yum; then
            yum install -y nginx
        else
            err "无法自动安装 Nginx。"
            return 1
        fi
    fi

    local public_ip dns_ip
    public_ip="$(get_public_ip)"
    dns_ip="$(getent ahostsv4 "$domain" 2>/dev/null | awk 'NR==1 {print $1}')"

    if [[ -z "$public_ip" || -z "$dns_ip" ]]; then
        err "无法获取服务器公网 IPv4 或域名解析结果。"
        return 1
    fi

    if [[ "$public_ip" != "$dns_ip" ]]; then
        warn "域名解析 IP：$dns_ip"
        warn "服务器公网 IP：$public_ip"
        err "域名解析与服务器公网 IP 不一致，请修正 DNS 后重试。"
        return 1
    fi

    if [[ -e "$NGINX_SITE" ]]; then
        err "检测到本脚本的 Nginx 配置文件已存在：$NGINX_SITE"
        err "为避免覆盖现有配置，请先检查并手动处理。"
        return 1
    fi

    token="$(openssl rand -hex 24)"
    printf '%s\n' "$token" > "$TOKEN_FILE"
    printf '%s\n' "$domain" > "$DOMAIN_FILE"
    printf '%s\n' "domain" > "$MODE_FILE"

    install -d -m 755 "$WEB_ROOT"
    install -d -m 755 "${WEB_ROOT}/sub"

    # Nginx 仅公开本脚本生成的订阅文件。
    cp "$SUB_FILE" "${WEB_ROOT}/sub/${token}"
    chmod 644 "${WEB_ROOT}/sub/${token}"

    cat > "$NGINX_SITE" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${domain};

    location = /sub/${token} {
        default_type text/plain;
        alias ${WEB_ROOT}/sub/${token};
        add_header Cache-Control "no-store";
    }

    location / {
        return 404;
    }
}
EOF

    if ! nginx -t; then
        rm -f "$NGINX_SITE"
        err "Nginx 配置检查失败，已删除本脚本刚创建的站点配置。"
        return 1
    fi

    systemctl enable --now nginx
    systemctl reload nginx

    install_certbot || return 1

    if ! certbot --nginx -d "$domain" \
        --non-interactive --agree-tos \
        --register-unsafely-without-email --redirect; then
        err "证书申请失败。未输出可用的 HTTPS 订阅地址。"
        return 1
    fi

    if ! nginx -t; then
        err "申请证书后 Nginx 配置检查失败。"
        return 1
    fi
    systemctl reload nginx

    local url
    url="https://${domain}/sub/${token}"

    # 远程 HTTPS 检查：失败时不宣称订阅可用。
    if ! curl -fsS --connect-timeout 8 --max-time 15 "$url" -o /dev/null; then
        err "HTTPS 订阅地址检查失败：$url"
        err "请检查防火墙、安全组、DNS、证书和 443 端口。"
        return 1
    fi

    printf '%s\n' "$url" > "${DATA_DIR}/subscribe_url"
    chmod 600 "${DATA_DIR}/subscribe_url"
    ok "HTTPS 订阅地址检查通过。"
    printf '%s\n' "$url"
}

install_node() {
    require_root
    install_packages
    ensure_dirs
    install_xray

    echo
    echo "请选择订阅模式："
    echo "1. 使用已解析域名（HTTPS 公网订阅）"
    echo "2. 不使用域名（仅输出节点连接和本地订阅内容）"
    echo
    read -r -p "请选择 [默认 2]：" mode
    mode="${mode:-2}"

    if [[ "$mode" != "1" && "$mode" != "2" ]]; then
        err "无效选项。"
        return 1
    fi

    local domain=""
    if [[ "$mode" == "1" ]]; then
        read -r -p "请输入已经解析到本机的域名（不带 https://）：" domain
        if [[ -z "$domain" ]]; then
            err "域名不能为空。"
            return 1
        fi
    fi

    local port uuid private_key public_key short_id address node
    port="$(choose_free_port)"
    uuid="$(cat /proc/sys/kernel/random/uuid)"
    short_id="$(openssl rand -hex 8)"

    local keys
    keys="$(generate_reality_keys)" || return 1
    private_key="$(printf '%s\n' "$keys" | sed -n '1p')"
    public_key="$(printf '%s\n' "$keys" | sed -n '2p')"

    write_xray_config "$uuid" "$port" "$private_key" "$short_id"

    if ! check_xray_config; then
        err "Xray 配置校验失败，未启动服务。"
        return 1
    fi

    write_service

    if ! systemctl restart "$SERVICE_NAME"; then
        err "Xray 服务启动失败。"
        systemctl --no-pager -l status "$SERVICE_NAME" || true
        return 1
    fi

    sleep 2
    if ! systemctl is-active --quiet "$SERVICE_NAME"; then
        err "Xray 服务未处于运行状态。"
        systemctl --no-pager -l status "$SERVICE_NAME" || true
        return 1
    fi

    address="$(get_public_ip)"
    if [[ -z "$address" ]]; then
        read -r -p "无法自动获取公网 IP，请输入服务器 IP：" address
    fi

    if [[ -z "$address" ]]; then
        err "服务器地址不能为空。"
        return 1
    fi

    node="$(make_vless_uri "$uuid" "$address" "$port" "$public_key" "$short_id" "Xiazheteng-REALITY")"

    printf '%s\n' "$node" > "$NODE_FILE"
    encode_subscription "$node"

    echo
    ok "VLESS-REALITY 节点部署完成。"
    echo
    echo "节点连接："
    echo "$node"
    echo
    echo "监听端口：$port"
    echo "Xray 服务：$SERVICE_NAME"
    echo "本地 Base64 订阅文件：$SUB_FILE"

    if [[ "$mode" == "1" ]]; then
        echo
        info "正在配置 HTTPS 公网订阅..."
        local url
        if url="$(setup_domain_subscription "$domain")"; then
            echo
            echo "公网订阅地址："
            echo "$url"
        else
            warn "公网订阅尚未验证成功，因此没有提供可用订阅地址。"
            warn "节点连接仍保存在：$NODE_FILE"
        fi
    else
        echo
        warn "当前使用无域名模式。"
        echo "本地 Base64 订阅内容："
        cat "$SUB_FILE"
        echo
        echo "此内容不是公网订阅 URL；需手动复制到客户端，或自行托管订阅内容。"
    fi

    echo
    info "如果 VPS 提供商有独立安全组，请确保放行 TCP ${port}。"
    info "REALITY 节点不需要为自身申请 TLS 证书。"
}

show_status() {
    echo
    echo "========== 服务状态 =========="
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        ok "Xray 服务运行中"
    else
        warn "Xray 服务未运行"
    fi
    systemctl --no-pager -l status "$SERVICE_NAME" 2>/dev/null || true

    echo
    echo "========== Xray 版本 =========="
    if [[ -x "$XRAY_BIN" ]]; then
        "$XRAY_BIN" version 2>/dev/null | head -n 3 || true
    else
        echo "未安装 Xray"
    fi
}

restart_xray() {
    if systemctl restart "$SERVICE_NAME"; then
        ok "已重启管理器 Xray 服务。"
    else
        err "重启失败。"
        systemctl --no-pager -l status "$SERVICE_NAME" || true
    fi
}

show_logs() {
    journalctl -u "$SERVICE_NAME" -n 100 --no-pager || true
}

update_xray() {
    require_root
    local installer
    installer="$(mktemp)"

    if ! curl -fL --retry 3 \
        "https://github.com/XTLS/Xray-install/raw/main/install-release.sh" \
        -o "$installer"; then
        rm -f "$installer"
        err "下载 Xray 更新脚本失败。"
        return 1
    fi

    bash "$installer" install
    local rc=$?
    rm -f "$installer"
    return "$rc"
}

show_node() {
    if [[ -r "$NODE_FILE" ]]; then
        echo
        cat "$NODE_FILE"
    else
        warn "尚未找到节点连接，请先执行一键安装。"
    fi
}

backup_config() {
    ensure_dirs
    local archive
    archive="${BACKUP_DIR}/backup-$(date +%Y%m%d-%H%M%S).tar.gz"

    tar -czf "$archive" -C "$BASE_DIR" config data
    chmod 600 "$archive"
    ok "备份已保存：$archive"
}

check_ports() {
    echo
    echo "========== TCP/UDP 监听端口 =========="
    if has_cmd ss; then
        ss -lntup
    else
        warn "系统没有 ss 命令。"
    fi
}

kernel_menu() {
    while true; do
        echo
        echo "========== 内核相关设置 =========="
        echo "1. 查看 Xray 服务状态"
        echo "2. 重启 Xray 服务"
        echo "3. 查看 Xray 日志"
        echo "4. 更新 Xray"
        echo "5. 查看节点连接"
        echo "6. 备份管理器配置"
        echo "7. 检查监听端口"
        echo "0. 返回主菜单"
        read -r -p "请选择：" choice

        case "$choice" in
            1) show_status; pause ;;
            2) restart_xray; pause ;;
            3) show_logs; pause ;;
            4) update_xray; pause ;;
            5) show_node; pause ;;
            6) backup_config; pause ;;
            7) check_ports; pause ;;
            0) return ;;
            *) warn "无效选项。" ;;
        esac
    done
}

install_upstream() {
    require_root
    install -d -m 700 "$(dirname "$UPSTREAM_FILE")"

    local tmp
    tmp="$(mktemp)"
    if ! curl -fL --retry 3 --connect-timeout 10 "$UPSTREAM_URL" -o "$tmp"; then
        rm -f "$tmp"
        err "下载勇哥 Sing-box 脚本失败。"
        return 1
    fi

    if ! head -n 1 "$tmp" | grep -q '^#!'; then
        rm -f "$tmp"
        err "下载内容不像有效的 Shell 脚本，已中止。"
        return 1
    fi

    install -m 700 "$tmp" "$UPSTREAM_FILE"
    rm -f "$tmp"
    ok "上游脚本已保存：$UPSTREAM_FILE"
}

run_upstream() {
    require_root

    if [[ ! -x "$UPSTREAM_FILE" ]]; then
        install_upstream || return 1
    fi

    warn "即将运行上游第三方脚本。该脚本具有 root 权限，请自行确认来源和内容。"
    read -r -p "确定继续？[y/N]：" confirm
    case "$confirm" in
        y|Y) bash "$UPSTREAM_FILE" ;;
        *) info "已取消。" ;;
    esac
}

show_subscription() {
    if [[ -r "$SUB_FILE" ]]; then
        echo
        echo "========== 本地 Base64 订阅内容 =========="
        cat "$SUB_FILE"
        echo
    else
        warn "尚未生成订阅内容。"
    fi

    if [[ -r "${DATA_DIR}/subscribe_url" ]]; then
        echo "记录的公网订阅地址："
        cat "${DATA_DIR}/subscribe_url"
    fi
}

enable_bbr() {
    require_root

    if ! grep -q 'net.core.default_qdisc=fq' /etc/sysctl.conf 2>/dev/null; then
        echo 'net.core.default_qdisc=fq' >> /etc/sysctl.conf
    fi
    if ! grep -q 'net.ipv4.tcp_congestion_control=bbr' /etc/sysctl.conf 2>/dev/null; then
        echo 'net.ipv4.tcp_congestion_control=bbr' >> /etc/sysctl.conf
    fi

    sysctl -p
    echo
    sysctl net.ipv4.tcp_congestion_control 2>/dev/null || true
    sysctl net.core.default_qdisc 2>/dev/null || true
}

check_https() {
    if [[ -r "${DATA_DIR}/subscribe_url" ]]; then
        local url
        url="$(cat "${DATA_DIR}/subscribe_url")"
        echo "正在检查：$url"
        curl -fsS -D - --connect-timeout 8 --max-time 15 "$url" -o /dev/null
    else
        warn "没有记录已验证的 HTTPS 订阅地址。"
        echo "若需要公网订阅，请重新运行一键安装并选择域名模式。"
    fi
}

update_manager() {
    require_root
    local installed="/usr/local/bin/${SCRIPT_NAME}"
    local tmp
    tmp="$(mktemp)"

    if ! curl -fL --retry 3 "$GITHUB_RAW" -o "$tmp"; then
        rm -f "$tmp"
        err "下载管理器更新失败。"
        return 1
    fi

    if ! bash -n "$tmp"; then
        rm -f "$tmp"
        err "下载的脚本未通过 Shell 语法检查，取消更新。"
        return 1
    fi

    install -m 700 "$tmp" "$installed"
    rm -f "$tmp"
    ok "管理器已更新：$installed"
}

more_menu() {
    while true; do
        echo
        echo "========== 更多功能 =========="
        echo "1. 打开勇哥 Sing-box 脚本菜单"
        echo "2. 下载/更新勇哥 Sing-box 脚本"
        echo "3. 查看本地 Base64 订阅"
        echo "4. 开启 BBR（修改系统 TCP 参数）"
        echo "5. 检查 HTTPS 订阅地址"
        echo "6. 更新本管理器"
        echo "0. 返回主菜单"
        read -r -p "请选择：" choice

        case "$choice" in
            1) run_upstream; pause ;;
            2) install_upstream; pause ;;
            3) show_subscription; pause ;;
            4) enable_bbr; pause ;;
            5) check_https; pause ;;
            6) update_manager; pause ;;
            0) return ;;
            *) warn "无效选项。" ;;
        esac
    done
}

install_shortcut() {
    require_root

    local installed="/usr/local/bin/${SCRIPT_NAME}"
    local shortcut="/usr/local/bin/x"

    if [[ "${BASH_SOURCE[0]}" != "$installed" ]]; then
        install -m 700 "${BASH_SOURCE[0]}" "$installed"
    fi

    cat > "$shortcut" <<EOF
#!/usr/bin/env bash
exec /usr/local/bin/${SCRIPT_NAME} "\$@"
EOF
    chmod 755 "$shortcut"
    ok "快捷启动命令已创建：x"
}

uninstall_manager() {
    require_root

    echo
    warn "此操作会删除本管理器的服务和配置。"
    warn "不会主动卸载全局 Xray，不会删除全局 Nginx，不会清空防火墙规则。"
    read -r -p "输入 DELETE 确认卸载：" confirm
    [[ "$confirm" == "DELETE" ]] || {
        info "已取消卸载。"
        return
    }

    systemctl disable --now "$SERVICE_NAME" >/dev/null 2>&1 || true
    rm -f "$SERVICE_FILE"
    systemctl daemon-reload

    # 只移除本脚本明确创建的 Nginx 配置及 Web 目录。
    # 如果 Nginx 配置曾被其他工具修改，卸载前请先检查。
    if [[ -f "$NGINX_SITE" ]] &&
        grep -q "server_name" "$NGINX_SITE" &&
        grep -q "$WEB_ROOT" "$NGINX_SITE"; then
        rm -f "$NGINX_SITE"
        nginx -t >/dev/null 2>&1 && systemctl reload nginx >/dev/null 2>&1 || true
    fi

    rm -rf "$BASE_DIR" "$WEB_ROOT" "/opt/${APP_NAME}"

    # 不删除全局 Xray 二进制、证书目录、Nginx 软件或其他网站。
    ok "管理器服务和本地配置已清理。"
    warn "如果之前申请过证书，Certbot 证书可能仍保留；请检查后再决定是否删除。"
    warn "快捷入口 /usr/local/bin/x 与 /usr/local/bin/${SCRIPT_NAME} 可能仍存在。"
    read -r -p "是否同时删除管理器快捷入口？[y/N]：" remove_shortcut
    if [[ "$remove_shortcut" == "y" || "$remove_shortcut" == "Y" ]]; then
        rm -f /usr/local/bin/x "/usr/local/bin/${SCRIPT_NAME}"
        ok "快捷入口已删除。"
    fi
}

main_menu() {
    while true; do
        clear 2>/dev/null || true
        echo "=================================================="
        echo "       瞎折腾吧 | VPS 节点管理器"
        echo "=================================================="
        echo "1. 一键安装"
        echo "2. 一键卸载"
        echo "3. 内核相关设置"
        echo "4. 更多功能"
        echo
        echo "输入 x 可快速启动脚本"
        echo "输入 q 退出"
        echo "=================================================="
        read -r -p "请输入选项：" choice

        case "$choice" in
            1) install_node; pause ;;
            2) uninstall_manager; pause ;;
            3) kernel_menu ;;
            4) more_menu ;;
            x|X)
                install_shortcut
                echo
                info "快捷入口已配置。下次可直接输入 x。"
                pause
                ;;
            q|Q) exit 0 ;;
            *) warn "无效选项。"; sleep 1 ;;
        esac
    done
}

main() {
    require_root
    ensure_dirs
    main_menu
}

main "$@"
