#!/usr/bin/env bash
# ============================================================
# 瞎折腾吧 | VPS 节点管理器
# Script: xiazheteng-node-manager.sh
# GitHub: https://github.com/xiazheteng8/xiazheteng-node-manager
# YouTube: https://www.youtube.com/@xiazheteng8
# Telegram: https://t.me/xiazheteng8
#
# 默认不使用域名。
# 主菜单 5：一键订阅所有已安装节点。
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
SUB_URL_FILE="${DATA_DIR}/subscribe_url"
SUB_SOURCE_DIR="${DATA_DIR}/sources"
SUB_EXPORT_DIR="${DATA_DIR}/export"

XRAY_BIN="/usr/local/bin/xray"
SERVICE_NAME="xiazheteng-node-manager.service"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}"

NGINX_SITE="/etc/nginx/conf.d/${APP_NAME}.conf"
WEB_ROOT="/var/www/${APP_NAME}"
UPSTREAM_FILE="/opt/${APP_NAME}/upstream/sb.sh"

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

ensure_dirs() {
    install -d -m 700 \
        "$BASE_DIR" "$CONFIG_DIR" "$DATA_DIR" \
        "$BACKUP_DIR" "$LOG_DIR" "$SUB_SOURCE_DIR" "$SUB_EXPORT_DIR"
}

detect_os() {
    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        OS_ID="${ID:-unknown}"
    else
        OS_ID="unknown"
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
        err "未识别的包管理器，请手动安装 curl、ca-certificates、openssl、python3。"
        return 1
    fi
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
    f"#{name}"
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

encode_subscription_file() {
    local input_file="$1" output_file="$2"

    if [[ ! -s "$input_file" ]]; then
        err "订阅源文件为空：$input_file"
        return 1
    fi

    base64 < "$input_file" | tr -d '\n' > "$output_file"
    printf '\n' >> "$output_file"
    chmod 600 "$output_file"
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
        yum install -y certbot python3-certbot-nginx || dnf install -y certbot
    else
        err "请手动安装 Certbot 及 Nginx 插件。"
        return 1
    fi
}

validate_domain() {
    [[ "$1" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,}$ ]]
}

setup_domain_subscription() {
    local domain="$1" token

    if ! validate_domain "$domain"; then
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
        err "域名解析 IP 与服务器公网 IP 不一致。"
        echo "域名 IP：$dns_ip"
        echo "服务器 IP：$public_ip"
        return 1
    fi

    if [[ -e "$NGINX_SITE" ]]; then
        err "本脚本的 Nginx 配置已存在：$NGINX_SITE"
        err "为避免覆盖配置，请先检查现有站点。"
        return 1
    fi

    token="$(openssl rand -hex 24)"
    printf '%s\n' "$token" > "$TOKEN_FILE"
    printf '%s\n' "$domain" > "$DOMAIN_FILE"
    printf '%s\n' "domain" > "$MODE_FILE"

    install -d -m 755 "$WEB_ROOT/sub"
    install -m 644 "$SUB_FILE" "${WEB_ROOT}/sub/${token}"

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
        err "Nginx 配置检查失败。"
        return 1
    fi

    systemctl enable --now nginx
    systemctl reload nginx

    install_certbot || return 1

    if ! certbot --nginx -d "$domain" \
        --non-interactive --agree-tos \
        --register-unsafely-without-email --redirect; then
        err "证书申请失败。"
        return 1
    fi

    nginx -t || return 1
    systemctl reload nginx

    local url="https://${domain}/sub/${token}"

    if ! curl -fsS --connect-timeout 8 --max-time 15 "$url" -o /dev/null; then
        err "HTTPS 订阅地址未通过检查：$url"
        return 1
    fi

    printf '%s\n' "$url" > "$SUB_URL_FILE"
    chmod 600 "$SUB_URL_FILE"
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
    read -r -p "请选择 [默认 2]：" mode
    mode="${mode:-2}"

    if [[ "$mode" != "1" && "$mode" != "2" ]]; then
        err "无效选项。"
        return 1
    fi

    local domain=""
    if [[ "$mode" == "1" ]]; then
        read -r -p "请输入已解析到本机的域名（不带 https://）：" domain
        if [[ -z "$domain" ]]; then
            err "域名不能为空。"
            return 1
        fi
    fi

    local port uuid private_key public_key short_id address node keys
    port="$(choose_free_port)"
    uuid="$(cat /proc/sys/kernel/random/uuid)"
    short_id="$(openssl rand -hex 8)"

    keys="$(generate_reality_keys)" || return 1
    private_key="$(printf '%s\n' "$keys" | sed -n '1p')"
    public_key="$(printf '%s\n' "$keys" | sed -n '2p')"

    write_xray_config "$uuid" "$port" "$private_key" "$short_id"

    if ! check_xray_config; then
        err "Xray 配置校验失败。"
        return 1
    fi

    write_service
    systemctl restart "$SERVICE_NAME"
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
    encode_subscription_file "$NODE_FILE" "$SUB_FILE"

    echo
    ok "VLESS-REALITY 节点部署完成。"
    echo
    echo "节点连接："
    cat "$NODE_FILE"
    echo
    echo "本地 Base64 订阅文件：$SUB_FILE"

    if [[ "$mode" == "1" ]]; then
        local url
        if url="$(setup_domain_subscription "$domain")"; then
            echo
            echo "公网订阅地址："
            echo "$url"
        else
            warn "公网订阅配置失败，未输出可用订阅 URL。"
        fi
    else
        echo
        warn "无域名模式：以下内容是 Base64 订阅，不是公网 URL。"
        cat "$SUB_FILE"
    fi

    echo
    info "请在 VPS 服务商安全组中放行 TCP ${port}。"
}

# ============================================================
# 一键订阅所有已安装节点
#
# 扫描：
#   Xray / V2Ray JSON
#   sing-box JSON
#   本管理器保存的节点连接
#   常见 share-link 文本文件
#
# 注意：
# 不会自动读取所有第三方脚本的私有数据库格式。
# 配置文件必须能被识别，才会加入合并订阅。
# ============================================================

scan_share_links() {
    local file="$1"

    [[ -f "$file" && -r "$file" ]] || return 0

    # 只抽取已知分享链接协议，避免把任意配置文本放进订阅。
    grep -Eo \
        '(vless|vmess|trojan|ss|ssr|hysteria2?|tuic|wireguard)://[^[:space:]"<>]+' \
        "$file" 2>/dev/null || true
}

scan_xray_json() {
    local file="$1"

    [[ -f "$file" && -r "$file" ]] || return 0
    has_cmd python3 || return 0

    python3 - "$file" <<'PY'
import json, sys, urllib.parse, base64

path = sys.argv[1]

try:
    with open(path, encoding="utf-8") as f:
        cfg = json.load(f)
except Exception:
    sys.exit(0)

def enc(s):
    return urllib.parse.quote(str(s), safe="")

for inbound in cfg.get("inbounds", []):
    try:
        protocol = str(inbound.get("protocol", "")).lower()
        port = inbound.get("port")
        settings = inbound.get("settings", {})
        stream = inbound.get("streamSettings", {})
        network = stream.get("network", "tcp")
        security = stream.get("security", "none")
        listen = inbound.get("listen", "")
        if not port:
            continue

        # 仅生成使用公网地址可连接的链接。
        # 0.0.0.0、:: 和空 listen 不是节点地址，必须由管理员补充公网 IP。
        address = listen
        if address in ("", "0.0.0.0", "::", "[::]", "localhost", "127.0.0.1"):
            continue

        if protocol == "vless":
            for client in settings.get("clients", []):
                uid = client.get("id")
                if not uid:
                    continue
                flow = client.get("flow", "")
                params = {
                    "encryption": "none",
                    "type": network,
                    "security": security
                }
                if flow:
                    params["flow"] = flow

                if security == "reality":
                    rs = stream.get("realitySettings", {})
                    names = rs.get("serverNames", [])
                    sids = rs.get("shortIds", [])
                    pbk = rs.get("publicKey", "")
                    if not pbk:
                        # 不能从私钥可靠推导公钥，跳过以避免生成无效链接。
                        continue
                    if names:
                        params["sni"] = names[0]
                    if sids:
                        params["sid"] = sids[0]
                    params["pbk"] = pbk
                elif security == "tls":
                    tls = stream.get("tlsSettings", {})
                    if tls.get("serverName"):
                        params["sni"] = tls["serverName"]

                query = urllib.parse.urlencode(params)
                print(f"vless://{uid}@{address}:{port}?{query}#{enc('scanned-vless')}")
        elif protocol == "trojan":
            for client in settings.get("clients", []):
                password = client.get("password")
                if not password:
                    continue
                params = {"type": network, "security": security}
                if security == "tls":
                    tls = stream.get("tlsSettings", {})
                    if tls.get("serverName"):
                        params["sni"] = tls["serverName"]
                query = urllib.parse.urlencode(params)
                print(f"trojan://{enc(password)}@{address}:{port}?{query}#{enc('scanned-trojan')}")
    except Exception:
        continue
PY
}

scan_singbox_json() {
    local file="$1"

    [[ -f "$file" && -r "$file" ]] || return 0
    has_cmd python3 || return 0

    python3 - "$file" <<'PY'
import json, sys, urllib.parse

try:
    with open(sys.argv[1], encoding="utf-8") as f:
        cfg = json.load(f)
except Exception:
    sys.exit(0)

def q(s):
    return urllib.parse.quote(str(s), safe="")

for ib in cfg.get("inbounds", []):
    try:
        typ = str(ib.get("type", "")).lower()
        tag = ib.get("tag", typ)
        port = ib.get("listen_port")
        address = ib.get("listen", "")
        if not port or not address:
            continue
        if address in ("0.0.0.0", "::", "127.0.0.1", "localhost", "[::]"):
            continue

        if typ == "shadowsocks":
            method = ib.get("method", "")
            password = ib.get("password", "")
            if method and password:
                raw = f"{method}:{password}".encode()
                userinfo = __import__("base64").urlsafe_b64encode(raw).decode().rstrip("=")
                print(f"ss://{userinfo}@{address}:{port}#{q(tag)}")

        elif typ == "trojan":
            password = ib.get("password", "")
            if password:
                tls = ib.get("tls", {})
                server_name = tls.get("server_name", "")
                query = {"security": "tls"} if tls.get("enabled") else {}
                if server_name:
                    query["sni"] = server_name
                suffix = "?" + urllib.parse.urlencode(query) if query else ""
                print(f"trojan://{q(password)}@{address}:{port}{suffix}#{q(tag)}")

        elif typ == "vless":
            users = ib.get("users", [])
            tls = ib.get("tls", {})
            for user in users:
                uid = user.get("uuid", "")
                if not uid:
                    continue
                query = {"encryption": "none", "type": "tcp"}
                if tls.get("enabled"):
                    query["security"] = "tls"
                    if tls.get("server_name"):
                        query["sni"] = tls["server_name"]
                else:
                    query["security"] = "none"
                print(f"vless://{uid}@{address}:{port}?{urllib.parse.urlencode(query)}#{q(tag)}")
    except Exception:
        continue
PY
}

discover_config_files() {
    # 限定常见目录和配置后缀；跳过 proc/sys/dev 等虚拟目录。
    local roots=(
        /usr/local/etc/xray
        /usr/local/etc/v2ray
        /etc/xray
        /etc/v2ray
        /etc/sing-box
        /usr/local/etc/sing-box
        /etc/singbox
        /opt
        /etc
    )

    local root
    for root in "${roots[@]}"; do
        [[ -d "$root" ]] || continue
        find "$root" -maxdepth 5 -type f \
            \( -iname '*.json' -o -iname '*.jsonc' -o -iname '*.txt' -o -iname '*.conf' \) \
            -not -path '/etc/ssl/*' \
            -not -path '/etc/letsencrypt/*' \
            -not -path '/etc/ssh/*' \
            -not -path '/etc/apt/*' \
            -not -path '/etc/systemd/*' \
            -not -path "$BASE_DIR/*" \
            -print 2>/dev/null || true
    done | sort -u
}

subscribe_all_nodes() {
    require_root
    ensure_dirs

    echo
    echo "========== 一键订阅所有已安装节点 =========="
    echo "将扫描常见 Xray、V2Ray、sing-box 配置及分享链接文件。"
    echo "仅能识别且能转换的节点才会被加入订阅。"
    echo

    local domain=""
    echo "请选择订阅发布方式："
    echo "1. 使用已解析域名，生成 HTTPS 公网订阅 URL"
    echo "2. 不使用域名，只生成本地 Base64 订阅"
    read -r -p "请选择 [默认 2]：" mode
    mode="${mode:-2}"

    if [[ "$mode" != "1" && "$mode" != "2" ]]; then
        err "无效选项。"
        return 1
    fi

    if [[ "$mode" == "1" ]]; then
        read -r -p "请输入已解析到本机的域名（不带 https://）：" domain
        if [[ -z "$domain" ]]; then
            err "域名不能为空。"
            return 1
        fi
        if ! validate_domain "$domain"; then
            err "域名格式不正确。"
            return 1
        fi
    fi

    local tmp raw_count config_count
    tmp="$(mktemp)"
    : > "$tmp"

    # 先纳入本管理器自己创建的分享链接。
    if [[ -r "$NODE_FILE" ]]; then
        cat "$NODE_FILE" >> "$tmp"
    fi

    # 读取常见的节点分享链接文本文件。
    local file
    while IFS= read -r file; do
        [[ -r "$file" ]] || continue
        case "$file" in
            *.txt|*.conf)
                scan_share_links "$file" >> "$tmp"
                ;;
        esac
    done < <(discover_config_files)

    # 扫描 JSON 配置，按 Xray/V2Ray 或 sing-box 格式尝试转换。
    while IFS= read -r file; do
        [[ -r "$file" ]] || continue
        case "$file" in
            *.json|*.jsonc)
                # 同一文件分别尝试两种格式；无法识别的配置不会产生输出。
                scan_xray_json "$file" >> "$tmp"
                scan_singbox_json "$file" >> "$tmp"
                ;;
        esac
    done < <(discover_config_files)

    # 去重并过滤空行。
    local merged="${SUB_SOURCE_DIR}/all-nodes.txt"
    grep -E '^(vless|vmess|trojan|ss|ssr|hysteria|hysteria2|tuic|wireguard)://' "$tmp" |
        sed 's/\r$//' |
        sort -u > "$merged" || true
    rm -f "$tmp"

    raw_count="$(grep -c . "$merged" 2>/dev/null || true)"
    raw_count="${raw_count:-0}"

    if [[ "$raw_count" -eq 0 ]]; then
        err "没有扫描到可用的节点分享链接。"
        warn "部分配置只保存监听地址或私钥，不能直接转换成客户端连接。"
        warn "请检查各协议的配置格式，或将现有分享链接保存到 .txt 文件后重新扫描。"
        return 1
    fi

    encode_subscription_file "$merged" "$SUB_FILE"

    echo
    ok "节点扫描和订阅合并完成。"
    echo "识别到的去重节点数量：$raw_count"
    echo "本地节点清单：$merged"
    echo "Base64 订阅文件：$SUB_FILE"
    echo
    echo "Base64 订阅内容："
    cat "$SUB_FILE"
    echo

    if [[ "$mode" == "1" ]]; then
        # 生成独立随机令牌路径，不能假设现有站点可被安全覆盖。
        if [[ -e "$NGINX_SITE" ]]; then
            err "发现管理器的 Nginx 配置已存在，为避免覆盖现有配置，本次不修改网站配置。"
            warn "本地 Base64 订阅已经生成；公网发布需要先检查已有 Nginx 配置。"
            return 1
        fi

        local url
        if url="$(setup_domain_subscription "$domain")"; then
            echo
            ok "公网订阅端点检查通过。"
            echo "一键订阅所有已识别节点："
            echo "$url"
        else
            err "公网订阅尚未通过验证。"
            warn "本地订阅文件已生成，但不能把它当成可用的 HTTPS 订阅地址。"
            return 1
        fi
    else
        warn "当前为无域名模式，没有生成公网订阅 URL。"
        echo "需要在客户端添加订阅时，可自行托管该 Base64 内容。"
    fi
}

show_status() {
    echo
    echo "========== 服务状态 =========="
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        ok "Xray 服务运行中"
    else
        warn "管理器 Xray 服务未运行"
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

    local installer rc
    installer="$(mktemp)"

    if ! curl -fL --retry 3 \
        "https://github.com/XTLS/Xray-install/raw/main/install-release.sh" \
        -o "$installer"; then
        rm -f "$installer"
        err "下载 Xray 更新脚本失败。"
        return 1
    fi

    bash "$installer" install
    rc=$?
    rm -f "$installer"
    return "$rc"
}

show_node() {
    if [[ -r "$NODE_FILE" ]]; then
        echo
        cat "$NODE_FILE"
    else
        warn "尚未找到本管理器生成的节点连接。"
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
        echo "5. 查看本管理器节点连接"
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

    warn "即将运行上游第三方脚本，该脚本具有 root 权限。"
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

    if [[ -r "$SUB_URL_FILE" ]]; then
        echo "已记录的公网订阅地址："
        cat "$SUB_URL_FILE"
    fi
}

enable_bbr() {
    require_root

    touch /etc/sysctl.conf

    if ! grep -q '^net.core.default_qdisc=fq$' /etc/sysctl.conf; then
        echo 'net.core.default_qdisc=fq' >> /etc/sysctl.conf
    fi

    if ! grep -q '^net.ipv4.tcp_congestion_control=bbr$' /etc/sysctl.conf; then
        echo 'net.ipv4.tcp_congestion_control=bbr' >> /etc/sysctl.conf
    fi

    sysctl -p
    echo
    sysctl net.ipv4.tcp_congestion_control 2>/dev/null || true
    sysctl net.core.default_qdisc 2>/dev/null || true
}

check_https() {
    if [[ -r "$SUB_URL_FILE" ]]; then
        local url
        url="$(cat "$SUB_URL_FILE")"
        echo "正在检查：$url"
        curl -fsS -D - --connect-timeout 8 --max-time 15 "$url" -o /dev/null
    else
        warn "没有记录已验证的 HTTPS 订阅地址。"
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
        echo "4. 开启 BBR"
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
    warn "不会主动卸载全局 Xray、Nginx 或清空防火墙规则。"
    read -r -p "输入 DELETE 确认卸载：" confirm

    [[ "$confirm" == "DELETE" ]] || {
        info "已取消卸载。"
        return
    }

    systemctl disable --now "$SERVICE_NAME" >/dev/null 2>&1 || true
    rm -f "$SERVICE_FILE"
    systemctl daemon-reload

    if [[ -f "$NGINX_SITE" ]] &&
        grep -q "$WEB_ROOT" "$NGINX_SITE"; then
        rm -f "$NGINX_SITE"
        nginx -t >/dev/null 2>&1 &&
            systemctl reload nginx >/dev/null 2>&1 || true
    fi

    rm -rf "$BASE_DIR" "$WEB_ROOT" "/opt/${APP_NAME}"

    ok "管理器服务和本地配置已清理。"
    warn "Certbot 证书可能仍然保留；请检查后再决定是否删除。"

    read -r -p "是否删除快捷入口？[y/N]：" remove_shortcut
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
        echo "5. 一键订阅所有已安装节点"
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
            5) subscribe_all_nodes; pause ;;
            x|X)
                install_shortcut
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
