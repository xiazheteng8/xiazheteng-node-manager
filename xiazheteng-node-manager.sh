
#!/usr/bin/env bash
# ============================================================
# 瞎折腾吧 | VPS 节点管理器 IPv4-only
# GitHub:   https://github.com/xiazheteng8/xiazheteng-node-manager
# YouTube:  https://www.youtube.com/@xiazheteng8
# Telegram: https://t.me/xiazheteng8
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
    if [[ "$EUID" -ne 0 ]]; then
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

# ------------------------------------------------------------
# 启动自恢复
# 解决 bash <(curl ...) 时 $0 指向 /dev/fd 的问题。
# 使用 /proc/$$/fd/255 等特殊路径时不直接 install 该路径。
# ------------------------------------------------------------
bootstrap_script() {
    local source="${BASH_SOURCE[0]}"
    local temp

    if [[ "$source" == "$MANAGER_PATH" ]]; then
        return 0
    fi

    if [[ -f "$source" && -r "$source" && "$source" != /dev/fd/* ]]; then
        install -m 700 "$source" "$MANAGER_PATH"
        return 0
    fi

    # Bash 通常会把脚本源文件保存在一个可读取的 FD 中。
    # 不假设 FD 编号固定，遍历常见 FD，检查内容是否为本脚本。
    for source in /proc/$$/fd/*; do
        [[ -r "$source" ]] || continue
        [[ -f "$source" ]] || continue

        if grep -q '瞎折腾吧 | VPS 节点管理器 IPv4-only' "$source" 2>/dev/null; then
            temp="$(mktemp "${BASE_DIR}.bootstrap.XXXXXX")"
            if cat "$source" > "$temp" 2>/dev/null && [[ -s "$temp" ]]; then
                install -m 700 "$temp" "$MANAGER_PATH"
                rm -f "$temp"
                return 0
            fi
            rm -f "$temp"
        fi
    done

    # 最后使用网络重新获取当前 GitHub 主分支版本。
    # 这避免把 /dev/fd 或 pipe 路径传给 install。
    if command -v curl >/dev/null 2>&1; then
        temp="$(mktemp "${BASE_DIR}.bootstrap.XXXXXX")"
        if curl -4 -fsSL \
            "https://raw.githubusercontent.com/xiazheteng8/xiazheteng-node-manager/main/xiazheteng-node-manager.sh" \
            -o "$temp" &&
            grep -q '^#!/usr/bin/env bash' "$temp" &&
            grep -q '瞎折腾吧 | VPS 节点管理器 IPv4-only' "$temp"; then
            install -m 700 "$temp" "$MANAGER_PATH"
            rm -f "$temp"
            return 0
        fi
        rm -f "$temp"
    fi

    warn "无法自动安装快捷入口，但仍尝试继续运行当前脚本。"
    return 0
}

install_shortcut() {
    mkdir -p /usr/local/bin

    # 不再对 /dev/fd、pipe 或 /proc/.../fd 路径执行 install。
    if [[ -f "$MANAGER_PATH" ]]; then
        chmod 700 "$MANAGER_PATH"
    else
        warn "管理脚本尚未保存为真实文件，快捷入口暂时无法安装。"
        return 0
    fi

    cat > "${SHORTCUT_PATH}.tmp" <<'SHORTCUT'
#!/usr/bin/env bash
exec /usr/local/bin/xiazheteng-node-manager.sh "$@"
SHORTCUT

    chmod 700 "${SHORTCUT_PATH}.tmp"
    mv "${SHORTCUT_PATH}.tmp" "$SHORTCUT_PATH"
    ok "快捷入口已安装：输入 x 即可启动。"
}

install_packages() {
    command -v apt-get >/dev/null 2>&1 || {
        err "当前脚本仅支持 Debian / Ubuntu。"
        return 1
    }

    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y \
        curl ca-certificates unzip openssl python3 nginx \
        certbot iproute2 coreutils util-linux dnsutils
}

get_public_ip() {
    local ip
    ip="$(curl -4 -fsS --max-time 8 https://api.ipify.org 2>/dev/null || true)"
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || \
        ip="$(curl -4 -fsS --max-time 8 https://ipv4.icanhazip.com 2>/dev/null || true)"

    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    printf '%s\n' "$ip"
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
            printf '%s\n' "$port"
            return 0
        fi
    done

    err "未找到可用端口。"
    return 1
}

validate_domain() {
    DOMAIN_TO_CHECK="${1,,}" python3 - <<'PY'
import os, re, sys
d = os.environ.get("DOMAIN_TO_CHECK", "").rstrip(".")
if len(d) > 253 or "." not in d:
    sys.exit(1)
labels = d.split(".")
if any(
    len(x) > 63 or
    not re.fullmatch(r"[a-z0-9](?:[a-z0-9-]*[a-z0-9])?", x)
    for x in labels
):
    sys.exit(1)
print(d)
PY
}

install_xray() {
    if [[ -x "$XRAY" ]]; then
        info "Xray 已安装：$("$XRAY" version 2>/dev/null | head -n 1)"
        return 0
    fi

    info "正在安装 Xray……"
    bash -c "$(curl -4 -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
    [[ -x "$XRAY" ]] || {
        err "未找到 Xray 执行文件。"
        return 1
    }
}

reality_keys() {
    local output
    output="$("$XRAY" x25519 2>&1)" || {
        printf '%s\n' "$output" >&2
        return 1
    }

    KEY_OUTPUT="$output" python3 - <<'PY'
import os, re, sys
s = os.environ["KEY_OUTPUT"]
fields = {}
for line in s.splitlines():
    if ":" in line:
        k, v = line.split(":", 1)
        fields[k.strip().lower()] = v.strip()

private = fields.get("privatekey") or fields.get("private key") or fields.get("private_key")
public = fields.get("password") or fields.get("publickey") or fields.get("public key") or fields.get("public_key")

if not private or not public:
    vals = re.findall(r"(?m)^\s*(?:Private key|Password \(Public key\)):\s*(\S+)", s)
    if len(vals) >= 2:
        private, public = vals[0], vals[1]

if not private or not public:
    print("无法识别 Xray REALITY 密钥格式。", file=sys.stderr)
    sys.exit(1)

print(private)
print(public)
PY
}

make_reality_link() {
    python3 - "$@" <<'PY'
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

    names = re.findall(r"(?m)^\s*server_name\s+([^;]+);", text)
    if not any(domain in [x.lower() for x in line.split()] for line in names):
        continue

    roots = re.findall(r"(?m)^\s*root\s+([^;]+);", text)
    for root in reversed(roots):
        root = root.strip().strip("\"'")
        if root.startswith("/") and os.path.isdir(root):
            print(root)
            sys.exit(0)

print("")
PY
}

configure_https_subscription() {
    local mode domain email root token cert_path dns_ips

    echo
    echo "请选择订阅模式："
    echo "1. 域名 + HTTPS 订阅"
    echo "2. 不使用域名（默认）"
    read -r -p "请选择 [默认 2]：" mode
    mode="${mode:-2}"

    if [[ "$mode" != "1" ]]; then
        rm -f "$SETTINGS_FILE" "$TOKEN_FILE" "$SUB_ROOT_FILE"
        info "已选择无域名模式。"
        return 0
    fi

    read -r -p "请输入已解析到本机的域名：" domain
    domain="$(validate_domain "$domain")" || {
        err "域名格式不正确。"
        return 1
    }

    read -r -p "请输入证书申请邮箱：" email
    [[ "$email" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] || {
        err "邮箱格式不正确。"
        return 1
    }

    dns_ips="$(dig +short A "$domain" 2>/dev/null | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' || true)"
    [[ -n "$dns_ips" ]] || {
        err "域名没有 IPv4 A 记录，请先配置 DNS。"
        return 1
    }

    root="$(find_existing_root "$domain" || true)"
    if [[ -n "$root" ]]; then
        NGINX_ROOT="$root"
        SUB_DIR="${root}/sub"
        info "检测到现有站点，复用网站根目录：$root"
        warn "不会删除或覆盖原站点的 Nginx 配置。"
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

    info "正在申请 HTTPS 证书……"
    certbot certonly --webroot -w "$NGINX_ROOT" -d "$domain" \
        --non-interactive --agree-tos --email "$email" || {
        err "证书申请失败。请检查 DNS、80 端口、ACME 路径及云安全组。"
        return 1
    }

    cert_path="/etc/letsencrypt/live/${domain}"
    [[ -s "$cert_path/fullchain.pem" && -s "$cert_path/privkey.pem" ]] || {
        err "证书文件不完整。"
        return 1
    }

    token="$(openssl rand -hex 24)"
    printf '%s\n' "$token" > "${TOKEN_FILE}.tmp"
    mv "${TOKEN_FILE}.tmp" "$TOKEN_FILE"
    printf '%s\n' "$domain" > "${SETTINGS_FILE}.tmp"
    mv "${SETTINGS_FILE}.tmp" "$SETTINGS_FILE"
    printf '%s\n' "$NGINX_ROOT" > "${SUB_ROOT_FILE}.tmp"
    mv "${SUB_ROOT_FILE}.tmp" "$SUB_ROOT_FILE"

    if [[ -n "$(find_existing_root "$domain" || true)" ]]; then
        # 保护现有站点，不进行不可靠的正则改写。
        nginx -t || {
            err "现有 Nginx 配置检查失败。"
            return 1
        }
        warn "证书已就绪，现有站点配置未修改。"
        warn "请确认该站点的 HTTPS server 已将 /sub/ 路由映射到：${NGINX_ROOT}/sub/"
        return 0
    fi

    if [[ -e "$NGINX_CONF" || -e "$NGINX_LINK" ]]; then
        err "本项目 Nginx 配置已存在，拒绝覆盖。"
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
        err "Nginx 配置测试失败，已撤销本次新增配置。"
        return 1
    fi

    if ! systemctl reload nginx; then
        rm -f "$NGINX_LINK" "$NGINX_CONF"
        nginx -t && systemctl reload nginx || true
        err "Nginx 重载失败，已撤销本次新增配置。"
        return 1
    fi

    ok "HTTPS 订阅站点已配置。"
}

write_subscription() {
    local token root output tmp
    [[ -s "$TOKEN_FILE" ]] || return 0

    token="$(cat "$TOKEN_FILE")"
    root="$NGINX_ROOT"
    [[ -s "$SUB_ROOT_FILE" ]] && root="$(cat "$SUB_ROOT_FILE")"

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
        if line.startswith(("vless://", "vmess://", "trojan://", "ss://")):
            lines.append(line)
data = "\n".join(dict.fromkeys(lines))
if data:
    data += "\n"
pathlib.Path(target).write_text(base64.b64encode(data.encode()).decode() + "\n")
PY

    chmod 644 "$tmp"
    mv "$tmp" "$output"

    if [[ -s "$SETTINGS_FILE" ]]; then
        echo "订阅地址：https://$(cat "$SETTINGS_FILE")/sub/${token}"
    fi
}

aggregate_nodes() {
    local tmp
    touch "$NODES_FILE"
    tmp="$(mktemp)"
    awk 'NF && !seen[$0]++' "$NODES_FILE" > "$tmp"
    install -m 600 "$tmp" "$NODES_FILE"
    rm -f "$tmp"
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
    local ip port uuid private_key public_key short_id name sni keys link tmp

    init_dirs
    install_packages || return 1
    configure_https_subscription || return 1
    install_xray || return 1

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
import json, os, sys
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
    tmp="$(mktemp)"
    {
        cat "$NODES_FILE"
        printf '%s\n' "$link"
    } | awk 'NF && !seen[$0]++' > "$tmp"
    install -m 600 "$tmp" "$NODES_FILE"
    rm -f "$tmp"

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
    warn "脚本不会清空或重置系统防火墙。"
}

show_nodes() {
    echo
    if [[ ! -s "$NODES_FILE" ]]; then
        warn "当前没有已记录节点。"
    else
        nl -ba "$NODES_FILE"
    fi
}

add_node() {
    local link
    read -r -p "请粘贴完整节点链接：" link
    case "$link" in
        vless://*|vmess://*|trojan://*|ss://*) ;;
        *)
            err "不支持的节点链接格式。"
            return 1
            ;;
    esac

    printf '%s\n' "$link" >> "$NODES_FILE"
    aggregate_nodes
    ok "节点已添加并去重。"
}

remove_node() {
    local number total tmp
    show_nodes
    total="$(wc -l < "$NODES_FILE")"
    (( total > 0 )) || return 0

    read -r -p "请输入要删除的行号：" number
    [[ "$number" =~ ^[0-9]+$ ]] || {
        err "行号无效。"
        return 1
    }
    (( number >= 1 && number <= total )) || {
        err "行号超出范围。"
        return 1
    }

    tmp="$(mktemp)"
    sed "${number}d" "$NODES_FILE" > "$tmp"
    install -m 600 "$tmp" "$NODES_FILE"
    rm -f "$tmp"
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
        echo "5. 查看监听端口"
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
    echo "GitHub：https://github.com/xiazheteng8/xiazheteng-node-manager"
    echo "YouTube：https://www.youtube.com/@xiazheteng8"
    echo "Telegram：https://t.me/xiazheteng8"
    echo
    warn "其他部署方式尚未集成到此版本。"
    pause
}

uninstall_project() {
    echo
    warn "将删除本项目的节点服务、配置和节点记录。"
    warn "不会清空系统防火墙，也不会删除其他网站配置。"
    read -r -p "输入 YES 确认卸载：" confirm
    [[ "$confirm" == "YES" ]] || return 0

    systemctl disable --now "$SERVICE_NAME" 2>/dev/null || true
    rm -f "$SERVICE_FILE"
    systemctl daemon-reload
    rm -rf "$BASE_DIR"

    if [[ -L "$NGINX_LINK" ]]; then
        local target
        target="$(readlink -f "$NGINX_LINK" 2>/dev/null || true)"
        [[ "$target" == "$NGINX_CONF" ]] && rm -f "$NGINX_LINK"
    fi

    if [[ -f "$NGINX_CONF" ]] &&
       grep -q "$APP_NAME" "$NGINX_CONF"; then
        rm -f "$NGINX_CONF"
    fi

    rm -f "/etc/letsencrypt/renewal-hooks/deploy/${APP_NAME}.sh"
    rm -f "$MANAGER_PATH" "$SHORTCUT_PATH"

    nginx -t && systemctl reload nginx || true
    ok "本项目服务与管理文件已清理。"
    warn "没有自动卸载系统级 Xray、Nginx 或 Certbot。"
}

main_menu() {
    while true; do
        clear 2>/dev/null || true
        echo "============================================================"
        echo "             瞎折腾吧 | VPS 节点管理器"
        echo "============================================================"
        echo "GitHub:   https://github.com/xiazheteng8/xiazheteng-node-manager"
        echo "YouTube:  https://www.youtube.com/@xiazheteng8"
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
        read -r -p "请选择（输入 x 返回主菜单）：" choice

        case "$choice" in
            1) deploy_reality; pause ;;
            2)
                warn "其他部署方式尚未集成。"
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

# 先把当前脚本保存到真实路径，随后再安装 x 快捷入口。
bootstrap_script
install_shortcut
main_menu
