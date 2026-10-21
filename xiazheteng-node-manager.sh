
#!/usr/bin/env bash
# ============================================================
# 瞎折腾吧 | VPS 节点管理器 IPv4-only
# GitHub:  https://github.com/xiazheteng8/xiazheteng-node-manager
# YouTube: https://www.youtube.com/@xiazheteng8
# Telegram: https://t.me/xiazheteng8
#
# 功能：
# 1. VLESS-REALITY 一键部署
# 2. 可选 HTTPS 订阅 / 默认不使用域名
# 3. 节点统一管理与订阅聚合
# 4. SSH 输入 x 快速启动
# 5. IPv4-only，不主动配置 IPv6 监听
# 6. 不清空防火墙，不覆盖其他站点完整配置
# ============================================================

set -Eeuo pipefail
umask 077

APP_NAME="xiazheteng-node-manager"
BASE_DIR="/etc/${APP_NAME}"
CONFIG_DIR="${BASE_DIR}/config"
DATA_DIR="${BASE_DIR}/data"
XRAY_CONFIG="${CONFIG_DIR}/xray.json"
NODES_FILE="${DATA_DIR}/nodes.txt"
SETTINGS_FILE="${BASE_DIR}/settings"
TOKEN_FILE="${BASE_DIR}/subscription-token"
SUB_ROOT_FILE="${BASE_DIR}/subscription-root"
MANAGER_PATH="/usr/local/bin/${APP_NAME}.sh"
SHORTCUT_PATH="/usr/local/bin/x"
SERVICE_NAME="${APP_NAME}.service"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}"
NGINX_ROOT="/var/www/html"
SUB_DIR="${NGINX_ROOT}/sub"
NGINX_CONF="/etc/nginx/sites-available/${APP_NAME}.conf"
NGINX_LINK="/etc/nginx/sites-enabled/${APP_NAME}.conf"
SNIPPET="/etc/nginx/snippets/${APP_NAME}-sub.conf"
XRAY="/usr/local/bin/xray"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

info() { echo -e "${BLUE}[信息]${NC} $*"; }
ok()   { echo -e "${GREEN}[成功]${NC} $*"; }
warn() { echo -e "${YELLOW}[提示]${NC} $*"; }
err()  { echo -e "${RED}[错误]${NC} $*" >&2; }

pause() {
    echo
    read -r -p "按回车键继续……" _
}

require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        err "请使用 root 用户运行。"
        exit 1
    fi
}

init_dirs() {
    mkdir -p "$CONFIG_DIR" "$DATA_DIR"
    touch "$NODES_FILE"
    chmod 700 "$BASE_DIR" "$CONFIG_DIR" "$DATA_DIR"
    chmod 600 "$NODES_FILE"
}

install_packages() {
    info "正在检查系统依赖……"

    if ! command -v apt-get >/dev/null 2>&1; then
        err "当前脚本仅支持 Debian / Ubuntu 系统。"
        return 1
    fi

    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y \
        curl ca-certificates unzip openssl python3 nginx \
        certbot iproute2 coreutils util-linux dnsutils
}

get_public_ip() {
    local ip=""
    ip="$(curl -4 -fsS --max-time 8 https://api.ipify.org 2>/dev/null || true)"

    if [[ -z "$ip" ]]; then
        ip="$(curl -4 -fsS --max-time 8 https://ipv4.icanhazip.com 2>/dev/null || true)"
    fi

    if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        printf '%s\n' "$ip"
    else
        return 1
    fi
}

port_in_use() {
    ss -H -lnt 2>/dev/null |
        awk '{print $4}' |
        grep -Eq "(:|\])${1}$"
}

random_port() {
    local i port
    for ((i=0; i<100; i++)); do
        port="$(shuf -i 20000-60000 -n 1)"
        if ! port_in_use "$port"; then
            echo "$port"
            return 0
        fi
    done

    err "无法找到可用端口。"
    return 1
}

validate_domain() {
    local domain="${1,,}"
    domain="${domain%.}"

    DOMAIN_TO_CHECK="$domain" python3 - <<'PY'
import os, re, sys
d = os.environ.get("DOMAIN_TO_CHECK", "")
if len(d) > 253 or not d or "." not in d:
    sys.exit(1)
labels = d.split(".")
if any(
    not re.fullmatch(r"[a-z0-9](?:[a-z0-9-]*[a-z0-9])?", x)
    or len(x) > 63
    for x in labels
):
    sys.exit(1)
print(d)
PY
}

install_shortcut() {
    local source
    source="$(readlink -f "$0")"

    if [[ "$source" != "$MANAGER_PATH" ]]; then
        install -m 700 "$source" "$MANAGER_PATH"
    fi

    cat > "$SHORTCUT_PATH" <<'SHORTCUT'
#!/usr/bin/env bash
exec /usr/local/bin/xiazheteng-node-manager.sh "$@"
SHORTCUT

    chmod 700 "$SHORTCUT_PATH"
    ok "管理入口已安装：输入 x 即可打开菜单。"
}

install_xray() {
    if [[ -x "$XRAY" ]]; then
        info "检测到已安装 Xray：$("$XRAY" version 2>/dev/null | head -n 1)"
        return 0
    fi

    info "正在安装 Xray……"
    bash -c "$(curl -4 -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

    [[ -x "$XRAY" ]] || {
        err "Xray 安装后未找到执行文件。"
        return 1
    }
}

reality_keys() {
    local output private_key public_key

    output="$("$XRAY" x25519 2>&1)" || {
        err "生成 REALITY 密钥失败。"
        printf '%s\n' "$output"
        return 1
    }

    read -r private_key public_key < <(
        KEY_OUTPUT="$output" python3 - <<'PY'
import os, re
s = os.environ["KEY_OUTPUT"]
fields = {}
for line in s.splitlines():
    if ":" in line:
        k, v = line.split(":", 1)
        fields[k.strip().lower()] = v.strip()

private = (
    fields.get("privatekey")
    or fields.get("private key")
    or fields.get("private_key")
)
public = (
    fields.get("password")
    or fields.get("publickey")
    or fields.get("public key")
    or fields.get("public_key")
)

if not private or not public:
    values = re.findall(r"(?m)^\s*(?:Private key|Password \(Public key\)):\s*(\S+)", s)
    if len(values) >= 2:
        private, public = values[0], values[1]

if private and public:
    print(private, public)
PY
    )

    if [[ -z "${private_key:-}" || -z "${public_key:-}" ]]; then
        err "无法识别当前 Xray 的密钥输出格式。"
        printf '%s\n' "$output"
        return 1
    fi

    printf '%s\n%s\n' "$private_key" "$public_key"
}

make_reality_link() {
    local uuid="$1" address="$2" port="$3" public_key="$4"
    local short_id="$5" name="$6" sni="$7"

    python3 - "$uuid" "$address" "$port" "$public_key" "$short_id" "$name" "$sni" <<'PY'
import sys, urllib.parse
uuid, address, port, key, sid, name, sni = sys.argv[1:]
params = {
    "encryption": "none",
    "security": "reality",
    "sni": sni,
    "fp": "chrome",
    "pbk": key,
    "sid": sid,
    "type": "tcp",
    "headerType": "none"
}
print(
    "vless://" + uuid + "@" + address + ":" + port + "?"
    + urllib.parse.urlencode(params)
    + "#" + urllib.parse.quote(name, safe="")
)
PY
}

# 从 Nginx 配置中寻找精确匹配域名的 root。
# 这里用于辅助判断，不直接修改第三方站点配置。
find_existing_root() {
    local domain="$1"

    python3 - "$domain" <<'PY'
import glob, os, re, sys

domain = sys.argv[1].lower()
files = []
for pattern in (
    "/etc/nginx/sites-enabled/*",
    "/etc/nginx/conf.d/*.conf",
    "/etc/nginx/sites-available/*"
):
    files.extend(glob.glob(pattern))

seen = set()

for path in files:
    real = os.path.realpath(path)
    if real in seen or not os.path.isfile(real):
        continue
    seen.add(real)

    try:
        text = open(real, encoding="utf-8", errors="ignore").read()
    except OSError:
        continue

    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    text = re.sub(r"(?m)#.*$", "", text)

    # 仅提取 server_name 和 root 供查找使用；
    # 不依赖此简化解析器来改写原站点。
    names = re.findall(r"(?m)^\s*server_name\s+([^;]+);", text)
    roots = re.findall(r"(?m)^\s*root\s+([^;]+);", text)

    if any(domain in [x.lower() for x in line.split()] for line in names):
        for root in reversed(roots):
            root = root.strip().strip("\"'")
            if root.startswith("/") and os.path.isdir(root):
                print(root)
                sys.exit(0)

print("")
PY
}

configure_https_subscription() {
    local domain email dns_ips existing_root cert_path token

    echo
    echo "订阅模式："
    echo "1. 域名 + HTTPS 订阅"
    echo "2. 不使用域名（默认）"
    read -r -p "请选择 [默认 2]：" mode
    mode="${mode:-2}"

    if [[ "$mode" != "1" ]]; then
        rm -f "$SETTINGS_FILE" "$TOKEN_FILE" "$SUB_ROOT_FILE"
        info "已选择无域名模式。"
        return 0
    fi

    read -r -p "请输入已解析到本机 IPv4 的域名：" domain
    domain="$(validate_domain "$domain")" || {
        err "域名格式不正确。"
        return 1
    }

    read -r -p "请输入证书申请邮箱：" email
    if [[ ! "$email" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]]; then
        err "邮箱格式不正确。"
        return 1
    fi

    dns_ips="$(dig +short A "$domain" 2>/dev/null | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' || true)"
    if [[ -z "$dns_ips" ]]; then
        err "域名没有有效的 IPv4 A 记录。"
        return 1
    fi

    existing_root="$(find_existing_root "$domain" || true)"

    if [[ -n "$existing_root" ]]; then
        NGINX_ROOT="$existing_root"
        SUB_DIR="${NGINX_ROOT}/sub"
        info "检测到现有站点，复用其网站目录：$NGINX_ROOT"
        warn "不会删除或覆盖原有 Nginx 站点配置。"
    else
        NGINX_ROOT="/var/www/html"
        SUB_DIR="${NGINX_ROOT}/sub"
    fi

    mkdir -p "$NGINX_ROOT" "$SUB_DIR" "$NGINX_ROOT/.well-known/acme-challenge"
    chmod 755 "$NGINX_ROOT" "$SUB_DIR"

    systemctl enable --now nginx || {
        err "Nginx 启动失败。"
        return 1
    }

    info "正在申请或续用 HTTPS 证书……"
    if ! certbot certonly \
        --webroot -w "$NGINX_ROOT" \
        -d "$domain" \
        --non-interactive --agree-tos \
        --email "$email"; then
        err "证书申请失败。请检查 DNS、80 端口及现有站点的 ACME 路径。"
        return 1
    fi

    cert_path="/etc/letsencrypt/live/${domain}"
    [[ -s "$cert_path/fullchain.pem" && -s "$cert_path/privkey.pem" ]] || {
        err "证书文件不存在或不完整。"
        return 1
    }

    token="$(openssl rand -hex 24)"
    printf '%s\n' "$token" > "${TOKEN_FILE}.tmp"
    mv "${TOKEN_FILE}.tmp" "$TOKEN_FILE"
    printf '%s\n' "$domain" > "${SETTINGS_FILE}.tmp"
    mv "${SETTINGS_FILE}.tmp" "$SETTINGS_FILE"
    printf '%s\n' "$NGINX_ROOT" > "${SUB_ROOT_FILE}.tmp"
    mv "${SUB_ROOT_FILE}.tmp" "$SUB_ROOT_FILE"

    if [[ -n "$existing_root" ]]; then
        # 不对未知结构的既有 server block 自动插入 location。
        # 防止误改反向代理、多个 server_name、嵌套 location 或第三方站点。
        warn "已复用现有站点目录，但现有 HTTPS 配置未被改写。"
        warn "需要现有 HTTPS server 提供 /sub/ 路由，才能通过该路径访问订阅。"
        warn "如当前站点没有 /sub/ 路由，部署会继续，但订阅链接可能暂时无法访问。"
        nginx -t || {
            err "现有 Nginx 配置测试失败。"
            return 1
        }
        return 0
    fi

    if [[ -e "$NGINX_CONF" || -e "$NGINX_LINK" ]]; then
        err "本项目的 Nginx 配置文件已存在，拒绝覆盖。"
        return 1
    fi

    cat > "${NGINX_CONF}.tmp" <<NGINX
server {
    listen 0.0.0.0:80;
    server_name ${domain};
    root ${NGINX_ROOT};

    location ^~ /.well-known/acme-challenge/ {
        try_files \$uri =404;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 0.0.0.0:443 ssl;
    server_name ${domain};
    root ${NGINX_ROOT};

    ssl_certificate ${cert_path}/fullchain.pem;
    ssl_certificate_key ${cert_path}/privkey.pem;

    location ^~ /sub/ {
        default_type text/plain;
        try_files \$uri =404;
    }

    location / {
        return 404;
    }
}
NGINX

    mv "${NGINX_CONF}.tmp" "$NGINX_CONF"
    ln -s "$NGINX_CONF" "$NGINX_LINK"

    if ! nginx -t; then
        rm -f "$NGINX_LINK" "$NGINX_CONF"
        err "新建 Nginx 配置检查失败，已撤销本次新增配置。"
        return 1
    fi

    if ! systemctl reload nginx; then
        rm -f "$NGINX_LINK" "$NGINX_CONF"
        nginx -t && systemctl reload nginx || true
        err "Nginx 重载失败，已撤销本次新增配置。"
        return 1
    fi

    mkdir -p /etc/letsencrypt/renewal-hooks/deploy
    cat > "/etc/letsencrypt/renewal-hooks/deploy/${APP_NAME}.sh" <<'HOOK'
#!/usr/bin/env bash
nginx -t && systemctl reload nginx
HOOK
    chmod 755 "/etc/letsencrypt/renewal-hooks/deploy/${APP_NAME}.sh"

    ok "HTTPS 订阅站点已配置。"
}

write_subscription() {
    local token root output tmp
    [[ -s "$TOKEN_FILE" ]] || return 0
    token="$(cat "$TOKEN_FILE")"

    root="$NGINX_ROOT"
    if [[ -s "$SUB_ROOT_FILE" ]]; then
        root="$(cat "$SUB_ROOT_FILE")"
    fi

    mkdir -p "${root}/sub"
    output="${root}/sub/${token}"
    tmp="${output}.tmp"

    python3 - "$NODES_FILE" "$tmp" <<'PY'
import base64, pathlib, sys
source, target = sys.argv[1:]
lines = []
p = pathlib.Path(source)
if p.exists():
    for line in p.read_text(errors="ignore").splitlines():
        line = line.strip()
        if line.startswith("vless://"):
            lines.append(line)
data = "\n".join(lines)
if data:
    data += "\n"
encoded = base64.b64encode(data.encode()).decode()
pathlib.Path(target).write_text(encoded + "\n")
PY

    chmod 644 "$tmp"
    mv "$tmp" "$output"
    ok "订阅文件已更新：$output"

    if [[ -s "$SETTINGS_FILE" ]]; then
        local domain
        domain="$(cat "$SETTINGS_FILE")"
        echo "订阅地址：https://${domain}/sub/${token}"
    fi
}

aggregate_nodes() {
    local temp
    temp="$(mktemp)"
    touch "$NODES_FILE"

    awk 'NF && !seen[$0]++' "$NODES_FILE" > "$temp"
    install -m 600 "$temp" "$NODES_FILE"
    rm -f "$temp"

    write_subscription
}

install_service() {
    cat > "${SERVICE_FILE}.tmp" <<SERVICE
[Unit]
Description=瞎折腾吧 Xray Node Manager
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${XRAY} run -config ${XRAY_CONFIG}
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
SERVICE

    mv "${SERVICE_FILE}.tmp" "$SERVICE_FILE"
    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME"
}

deploy_reality() {
    local ip port uuid private_key public_key short_id name sni link
    local keys

    init_dirs
    install_packages || return 1
    configure_https_subscription || return 1
    install_xray || return 1
    install_shortcut

    ip="$(get_public_ip)" || {
        err "无法获取 VPS 公网 IPv4。"
        return 1
    }

    port="$(random_port)" || return 1
    uuid="$(cat /proc/sys/kernel/random/uuid)"
    short_id="$(openssl rand -hex 8)"
    sni="www.microsoft.com"
    name="瞎折腾吧-REALITY-${port}"

    keys="$(reality_keys)" || return 1
    private_key="$(printf '%s\n' "$keys" | sed -n '1p')"
    public_key="$(printf '%s\n' "$keys" | sed -n '2p')"

    python3 - "$XRAY_CONFIG" "$port" "$uuid" "$private_key" "$short_id" "$sni" <<'PY'
import json, sys, os
path, port, uuid, private_key, short_id, sni = sys.argv[1:]
data = {
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
      "network": "raw",
      "security": "reality",
      "realitySettings": {
        "show": False,
        "dest": sni + ":443",
        "xver": 0,
        "serverNames": [sni],
        "privateKey": private_key,
        "shortIds": [short_id]
      }
    },
    "sniffing": {
      "enabled": True,
      "destOverride": ["http", "tls", "quic"]
    }
  }],
  "outbounds": [{"protocol": "freedom", "tag": "direct"}]
}
tmp = path + ".tmp"
with open(tmp, "w") as f:
    json.dump(data, f, indent=2)
os.chmod(tmp, 0o600)
os.replace(tmp, path)
PY

    "$XRAY" run -test -config "$XRAY_CONFIG" || {
        err "Xray 配置检查失败。"
        return 1
    }

    install_service
    systemctl restart "$SERVICE_NAME" || {
        err "Xray 服务启动失败。"
        journalctl -u "$SERVICE_NAME" -n 40 --no-pager || true
        return 1
    }

    link="$(make_reality_link "$uuid" "$ip" "$port" "$public_key" "$short_id" "$name" "$sni")"

    grep -Fvx "$link" "$NODES_FILE" > "${NODES_FILE}.tmp" || true
    printf '%s\n' "$link" >> "${NODES_FILE}.tmp"
    awk 'NF && !seen[$0]++' "${NODES_FILE}.tmp" > "${NODES_FILE}.new"
    install -m 600 "${NODES_FILE}.new" "$NODES_FILE"
    rm -f "${NODES_FILE}.tmp" "${NODES_FILE}.new"

    aggregate_nodes

    echo
    ok "VLESS-REALITY 节点部署完成。"
    echo "服务器 IPv4：$ip"
    echo "端口：$port"
    echo "UUID：$uuid"
    echo "SNI：$sni"
    echo "Public Key：$public_key"
    echo "Short ID：$short_id"
    echo
    echo "节点链接："
    echo "$link"
    echo
    warn "请在 VPS 云平台安全组中放行 TCP ${port}。"
    warn "本脚本不会清空或重置系统防火墙。"
}

show_nodes() {
    echo
    if [[ ! -s "$NODES_FILE" ]]; then
        warn "当前没有已记录节点。"
        return
    fi

    nl -ba "$NODES_FILE"
}

add_node() {
    local link
    read -r -p "请粘贴完整节点链接：" link
    if [[ "$link" != vless://* && "$link" != vmess://* && "$link" != trojan://* && "$link" != ss://* ]]; then
        err "暂不支持该链接格式。"
        return 1
    fi

    printf '%s\n' "$link" >> "$NODES_FILE"
    aggregate_nodes
    ok "节点已添加并去重。"
}

remove_node() {
    local number total temp
    show_nodes
    total="$(wc -l < "$NODES_FILE")"
    [[ "$total" -gt 0 ]] || return 0

    read -r -p "请输入要删除的行号：" number
    [[ "$number" =~ ^[0-9]+$ ]] || {
        err "行号无效。"
        return 1
    }
    (( number >= 1 && number <= total )) || {
        err "行号超出范围。"
        return 1
    }

    temp="$(mktemp)"
    sed "${number}d" "$NODES_FILE" > "$temp"
    install -m 600 "$temp" "$NODES_FILE"
    rm -f "$temp"
    aggregate_nodes
    ok "节点已删除。"
}

service_menu() {
    while true; do
        echo
        echo "===== 系统与服务设置 ====="
        echo "1. 查看 Xray 状态"
        echo "2. 重启 Xray"
        echo "3. 查看 Xray 日志"
        echo "4. 检查 Xray 配置"
        echo "5. 显示监听端口"
        echo "0. 返回"
        read -r -p "请选择：" choice

        case "$choice" in
            1) systemctl status "$SERVICE_NAME" --no-pager || true ;;
            2) systemctl restart "$SERVICE_NAME" && ok "已重启。" ;;
            3) journalctl -u "$SERVICE_NAME" -n 80 --no-pager || true ;;
            4) "$XRAY" run -test -config "$XRAY_CONFIG" ;;
            5) ss -lntp ;;
            0|x|X) return ;;
            *) warn "无效选项。" ;;
        esac
        pause
    done
}

manage_nodes_menu() {
    while true; do
        echo
        echo "===== 节点管理与订阅聚合 ====="
        echo "1. 查看所有节点"
        echo "2. 添加节点链接"
        echo "3. 删除节点"
        echo "4. 重新聚合订阅"
        echo "5. 显示订阅地址"
        echo "0. 返回"
        read -r -p "请选择：" choice

        case "$choice" in
            1) show_nodes ;;
            2) add_node ;;
            3) remove_node ;;
            4) aggregate_nodes ;;
            5)
                if [[ -s "$SETTINGS_FILE" && -s "$TOKEN_FILE" ]]; then
                    echo "https://$(cat "$SETTINGS_FILE")/sub/$(cat "$TOKEN_FILE")"
                else
                    warn "当前未配置 HTTPS 订阅。"
                fi
                ;;
            0|x|X) return ;;
            *) warn "无效选项。" ;;
        esac
        pause
    done
}

more_menu() {
    echo
    echo "===== 更多功能 ====="
    echo "项目：${APP_NAME}"
    echo "GitHub：https://github.com/xiazheteng8/xiazheteng-node-manager"
    echo "YouTube：https://www.youtube.com/@xiazheteng8"
    echo "Telegram：https://t.me/xiazheteng8"
    echo
    warn "其他部署方式尚未集成到此版本。"
    pause
}

uninstall_project() {
    echo
    warn "此操作会删除本项目管理的 Xray 节点服务、配置和节点记录。"
    warn "不会清空系统防火墙，也不会主动删除其他网站配置。"
    read -r -p "输入 YES 确认卸载：" confirm
    [[ "$confirm" == "YES" ]] || return 0

    systemctl disable --now "$SERVICE_NAME" 2>/dev/null || true
    rm -f "$SERVICE_FILE"
    systemctl daemon-reload

    rm -rf "$BASE_DIR"

    # 只删除本项目明确创建的 Nginx 配置链接和文件。
    if [[ -L "$NGINX_LINK" ]]; then
        target="$(readlink -f "$NGINX_LINK" 2>/dev/null || true)"
        if [[ "$target" == "$NGINX_CONF" ]]; then
            rm -f "$NGINX_LINK"
        fi
    fi

    if [[ -f "$NGINX_CONF" ]] &&
       grep -q "server_name" "$NGINX_CONF" &&
       grep -q "/sub/" "$NGINX_CONF"; then
        rm -f "$NGINX_CONF"
    fi

    rm -f "/etc/letsencrypt/renewal-hooks/deploy/${APP_NAME}.sh"
    rm -f "$MANAGER_PATH" "$SHORTCUT_PATH"

    nginx -t && systemctl reload nginx || true

    ok "本项目服务与管理文件已清理。"
    warn "为避免影响其他软件，本脚本不会自动卸载全局 Xray、Nginx 或 Certbot。"
}

main_menu() {
    while true; do
        clear 2>/dev/null || true
        echo "============================================================"
        echo "             瞎折腾吧 | VPS 节点管理器"
        echo "============================================================"
        echo "GitHub:  https://github.com/xiazheteng8/xiazheteng-node-manager"
        echo "YouTube: https://www.youtube.com/@xiazheteng8"
        echo "Telegram: https://t.me/xiazheteng8"
        echo
        echo "1. 一键部署 VLESS-REALITY"
        echo "2. 其他部署方式"
        echo "3. 节点管理与订阅聚合"
        echo "4. 系统与服务设置"
        echo "5. 更多功能"
        echo "6. 卸载本项目节点服务"
        echo "0. 退出"
        echo
        read -r -p "请选择（输入 x 也可返回主菜单）：" choice

        case "$choice" in
            1) deploy_reality; pause ;;
            2)
                warn "其他部署方式尚未集成。"
                warn "本选项不会伪装成已实现的部署功能。"
                pause
                ;;
            3) init_dirs; manage_nodes_menu ;;
            4) service_menu ;;
            5) more_menu ;;
            6) uninstall_project; pause ;;
            0|q|Q) exit 0 ;;
            x|X) continue ;;
            *) warn "无效选项。"; pause ;;
        esac
    done
}

require_root
init_dirs
install_shortcut
main_menu
