
#!/usr/bin/env bash
# ============================================================
# 瞎折腾吧 | VPS 节点管理器
# GitHub:  https://github.com/xiazheteng8/xiazheteng-node-manager
# YouTube: https://www.youtube.com/@xiazheteng8
# Telegram: https://t.me/xiazheteng8
#
# 功能：
#   1. VLESS-REALITY 一键部署
#   2. 默认不使用域名
#   3. 可选域名 HTTPS 订阅
#   4. 聚合已登记节点的统一订阅
#   5. 自动检测端口冲突并重新选择
#   6. 自动创建 x 快捷启动命令
#   7. IPv4-only，不清空防火墙、不覆盖其他网站
# ============================================================

set -Eeuo pipefail
umask 077

VERSION="2.0.0"

BASE_DIR="/etc/xiazheteng-node-manager"
CONFIG_DIR="$BASE_DIR/config"
DATA_DIR="$BASE_DIR/data"
LOG_DIR="$BASE_DIR/logs"

XRAY_CONFIG="$CONFIG_DIR/xray.json"
NODES_FILE="$DATA_DIR/nodes.txt"
SUB_FILE="$DATA_DIR/subscription.txt"
TOKEN_FILE="$DATA_DIR/subscription.token"

MANAGER_PATH="/usr/local/bin/xiazheteng-node-manager.sh"
SHORTCUT_PATH="/usr/local/bin/x"

SERVICE_NAME="xiazheteng-node-manager"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

WEB_ROOT="/var/www/html"
SUB_DIR="$WEB_ROOT/sub"
NGINX_CONF="/etc/nginx/sites-available/xiazheteng-node-manager.conf"
NGINX_LINK="/etc/nginx/sites-enabled/xiazheteng-node-manager.conf"

log()  { printf '\033[32m[信息]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[警告]\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[31m[错误]\033[0m %s\n' "$*" >&2; }
die()  { err "$*"; return 1; }

pause() {
    echo
    read -r -p "按回车键继续..." _ || true
}

need_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        die "请使用 root 用户运行。"
        return 1
    fi
}

init_dirs() {
    mkdir -p "$CONFIG_DIR" "$DATA_DIR" "$LOG_DIR"
    touch "$NODES_FILE"
    chmod 700 "$BASE_DIR" "$CONFIG_DIR" "$DATA_DIR" "$LOG_DIR"
    chmod 600 "$NODES_FILE"
}

install_packages() {
    export DEBIAN_FRONTEND=noninteractive

    if command -v apt-get >/dev/null 2>&1; then
        apt-get update
        apt-get install -y \
            curl ca-certificates openssl python3 \
            socat cron
    else
        die "当前脚本仅支持 Debian / Ubuntu 系统。"
        return 1
    fi
}

get_ipv4() {
    local ip=""
    local url

    for url in \
        "https://api.ipify.org" \
        "https://ipv4.icanhazip.com" \
        "https://checkip.amazonaws.com"
    do
        ip="$(curl -4 -fsS --connect-timeout 4 --max-time 8 "$url" 2>/dev/null \
            | tr -d '[:space:]' || true)"

        if [[ -n "$ip" ]] && python3 - "$ip" <<'PY'
import ipaddress, sys
try:
    ipaddress.IPv4Address(sys.argv[1])
except Exception:
    sys.exit(1)
PY
        then
            printf '%s\n' "$ip"
            return 0
        fi
    done

    return 1
}

install_xray() {
    if [[ -x /usr/local/bin/xray ]]; then
        log "检测到已有 Xray：$(/usr/local/bin/xray version 2>/dev/null | head -n 1)"
        return 0
    fi

    log "正在安装 Xray..."

    bash -c "$(curl -4 -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

    [[ -x /usr/local/bin/xray ]] || {
        die "Xray 安装后未找到 /usr/local/bin/xray。"
        return 1
    }
}

# 读取 Xray x25519 的不同输出格式。
# PrivateKey 只能用于私钥；Password/PublicKey 用作公钥候选。
generate_reality_keys() {
    local output
    output="$(/usr/local/bin/xray x25519 2>&1)" || {
        printf '%s\n' "$output" >&2
        return 1
    }

    python3 - "$output" <<'PY'
import re, sys

text = sys.argv[1]
fields = {}

for line in text.splitlines():
    if ":" not in line:
        continue
    k, v = line.split(":", 1)
    key = re.sub(r"[^a-z]", "", k.lower())
    fields[key] = v.strip()

private = (
    fields.get("privatekey")
    or fields.get("private")
    or fields.get("secretkey")
)

public = (
    fields.get("publickey")
    or fields.get("public")
    or fields.get("passwordpublickey")
    or fields.get("password")
)

# 新旧版本输出标签可能不同。
# 如果找不到字段，尝试识别形如 Base64 的密钥行。
if not private or not public:
    values = [
        re.sub(r"\s+", "", x)
        for x in re.findall(r":\s*([A-Za-z0-9_+/=-]{20,})", text)
    ]
    values = list(dict.fromkeys(values))
    if not private and values:
        private = values[0]
    if not public and len(values) >= 2:
        public = values[1]

if not private or not public:
    print("无法识别当前 Xray 的密钥输出格式。", file=sys.stderr)
    print(text, file=sys.stderr)
    sys.exit(1)

print(private)
print(public)
PY
}

port_in_use() {
    local port="$1"

    if command -v ss >/dev/null 2>&1; then
        ss -H -lnt 2>/dev/null |
            awk '{print $4}' |
            grep -Eq "(:|\])${port}$"
    else
        return 1
    fi
}

random_free_port() {
    local preferred="${1:-}"
    local port
    local tries=0

    if [[ "$preferred" =~ ^[0-9]+$ ]] &&
       (( preferred >= 1024 && preferred <= 65535 )) &&
       ! port_in_use "$preferred"
    then
        printf '%s\n' "$preferred"
        return 0
    fi

    while (( tries < 150 )); do
        port="$(shuf -i 20000-60000 -n 1)"
        if ! port_in_use "$port"; then
            printf '%s\n' "$port"
            return 0
        fi
        ((tries+=1))
    done

    die "无法找到可用端口。"
    return 1
}

valid_domain() {
    local domain="$1"

    [[ "$domain" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] &&
    [[ "$domain" == *.* ]] &&
    [[ "$domain" != *..* ]] &&
    (( ${#domain} <= 253 ))
}

# 只判断精确 server_name token。
# 不把 example.com 和 sub.example.com 错误地视为同一个域名。
nginx_domain_conflict() {
    local domain="$1"
    local dump

    command -v nginx >/dev/null 2>&1 || return 1

    dump="$(nginx -T 2>/dev/null || true)"

    printf '%s\n' "$dump" |
        awk -v wanted="$domain" '
        /^[[:space:]]*server_name[[:space:]]/ {
            line=$0
            sub(/;.*/, "", line)
            sub(/^[[:space:]]*server_name[[:space:]]+/, "", line)
            n=split(line, names, /[[:space:]]+/)
            for (i=1; i<=n; i++) {
                if (names[i] == wanted) found=1
            }
        }
        END { exit(found ? 0 : 1) }
        '
}

nginx_has_http_listener() {
    command -v nginx >/dev/null 2>&1 || return 1

    nginx -T 2>/dev/null |
        grep -Eq '^[[:space:]]*listen[[:space:]]+([^;]*:)?80([[:space:];]|$)'
}

nginx_has_https_listener() {
    command -v nginx >/dev/null 2>&1 || return 1

    nginx -T 2>/dev/null |
        grep -Eq '^[[:space:]]*listen[[:space:]]+([^;]*:)?443([[:space:];]|$)'
}

create_token() {
    openssl rand -hex 24
}

write_node_registry() {
    local name="$1"
    local link="$2"

    touch "$NODES_FILE"
    chmod 600 "$NODES_FILE"

    # 用名称更新已有记录，避免重复登记。
    local tmp
    tmp="$(mktemp)"

    awk -F'|' -v name="$name" '$1 != name { print }' "$NODES_FILE" > "$tmp" || true
    printf '%s|%s\n' "$name" "$link" >> "$tmp"
    install -m 600 "$tmp" "$NODES_FILE"
    rm -f "$tmp"
}

make_reality_link() {
    local name="$1"
    local ip="$2"
    local port="$3"
    local uuid="$4"
    local public_key="$5"
    local short_id="$6"
    local sni="$7"

    python3 - "$name" "$ip" "$port" "$uuid" "$public_key" "$short_id" "$sni" <<'PY'
import sys, urllib.parse
name, ip, port, uid, key, sid, sni = sys.argv[1:]
params = {
    "encryption": "none",
    "security": "reality",
    "sni": sni,
    "fp": "chrome",
    "pbk": key,
    "sid": sid,
    "type": "tcp",
    "flow": "xtls-rprx-vision",
}
query = urllib.parse.urlencode(params)
print(f"vless://{uid}@{ip}:{port}?{query}#{urllib.parse.quote(name)}")
PY
}

write_xray_config() {
    local port="$1"
    local uuid="$2"
    local private_key="$3"
    local short_id="$4"
    local sni="$5"

    python3 - "$XRAY_CONFIG" "$port" "$uuid" "$private_key" "$short_id" "$sni" <<'PY'
import json, sys, os

path, port, uid, private, sid, sni = sys.argv[1:]
config = {
    "log": {"loglevel": "warning"},
    "inbounds": [{
        "tag": "xiazheteng-vless-reality",
        "listen": "0.0.0.0",
        "port": int(port),
        "protocol": "vless",
        "settings": {
            "clients": [{"id": uid, "flow": "xtls-rprx-vision"}],
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
                "privateKey": private,
                "shortIds": [sid]
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
    ],
    "routing": {
        "domainStrategy": "AsIs",
        "rules": [{
            "type": "field",
            "ip": ["geoip:private"],
            "outboundTag": "block"
        }]
    }
}

os.makedirs(os.path.dirname(path), exist_ok=True)
tmp = path + ".tmp"
with open(tmp, "w") as f:
    json.dump(config, f, indent=2)
os.chmod(tmp, 0o600)
os.replace(tmp, path)
PY

    /usr/local/bin/xray run -test -config "$XRAY_CONFIG"
}

install_manager_service() {
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Xiazheteng Node Manager Xray Instance
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/xray run -config $XRAY_CONFIG
Restart=on-failure
RestartSec=3
User=root
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

    chmod 644 "$SERVICE_FILE"
    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME" >/dev/null
}

restart_manager_service() {
    systemctl restart "$SERVICE_NAME"
    sleep 1

    if ! systemctl is-active --quiet "$SERVICE_NAME"; then
        journalctl -u "$SERVICE_NAME" -n 40 --no-pager || true
        die "Xray 服务启动失败，请检查日志。"
        return 1
    fi
}

aggregate_subscription() {
    local tmp
    tmp="$(mktemp)"

    if [[ -f "$NODES_FILE" ]]; then
        awk -F'|' 'NF >= 2 && $2 ~ /^vless:\/\// {print $2}' "$NODES_FILE" |
            awk '!seen[$0]++' > "$tmp" || true
    fi

    install -m 600 "$tmp" "$SUB_FILE"
    rm -f "$tmp"

    log "统一订阅文件：$SUB_FILE"
    log "已登记节点数：$(grep -c '^vless://' "$SUB_FILE" 2>/dev/null || true)"
}

setup_local_subscription() {
    aggregate_subscription
    warn "当前使用本地统一订阅文件，未生成可从公网访问的 HTTPS 订阅 URL。"
    printf '订阅文件：%s\n' "$SUB_FILE"
}

# 只创建独立配置，不修改或覆盖已有站点配置。
# 如果域名已被使用，先尝试安全地复用现有网站根目录。
# 无法确认现有站点路由行为时，不擅自插入 server/location 块。
setup_https_subscription() {
    local domain="$1"
    local token="$2"
    local webroot="$WEB_ROOT"
    local cert_dir="/etc/letsencrypt/live/$domain"
    local cert_file="$cert_dir/fullchain.pem"
    local key_file="$cert_dir/privkey.pem"
    local conflict=0

    if ! valid_domain "$domain"; then
        warn "域名格式无效，回退到本地订阅文件。"
        setup_local_subscription
        return 0
    fi

    if ! command -v nginx >/dev/null 2>&1; then
        if ! apt-get install -y nginx; then
            warn "无法安装 Nginx，回退到本地订阅文件。"
            setup_local_subscription
            return 0
        fi
    fi

    if nginx_domain_conflict "$domain"; then
        conflict=1
    fi

    if (( conflict )); then
        warn "检测到 Nginx 已存在精确匹配的域名站点：$domain"
        warn "不会覆盖该站点配置。尝试寻找可复用的网站根目录。"

        # 只有当当前配置中能明确找到 root 指令时才尝试复用。
        # 此处不自动编辑现有 server 块，也不假设 location 路由一定允许访问。
        local existing_root
        existing_root="$(
            nginx -T 2>/dev/null |
            awk -v wanted="$domain" '
                /^[[:space:]]*server_name[[:space:]]/ {
                    line=$0
                    sub(/;.*/, "", line)
                    sub(/^[[:space:]]*server_name[[:space:]]+/, "", line)
                    n=split(line, names, /[[:space:]]+/)
                    matched=0
                    for (i=1; i<=n; i++) if (names[i] == wanted) matched=1
                    in_server=matched
                }
                in_server && /^[[:space:]]*root[[:space:]]+/ {
                    line=$0
                    sub(/^[[:space:]]*root[[:space:]]+/, "", line)
                    sub(/;.*/, "", line)
                    gsub(/["\047]/, "", line)
                    print line
                    exit
                }
            '
        )"

        if [[ -n "$existing_root" && -d "$existing_root" &&
              -w "$existing_root" ]]; then
            webroot="$existing_root"
            warn "找到可写的网站根目录：$webroot"
            warn "订阅文件将写入该目录的 sub/ 子目录。"
            warn "现有站点可能使用反向代理或自定义路由；请部署后验证 URL。"
        else
            warn "无法安全确认可复用的网站根目录。"
            warn "不修改现有站点，自动回退到本地统一订阅文件。"
            setup_local_subscription
            return 0
        fi
    fi

    mkdir -p "$webroot/sub"
    chmod 755 "$webroot" "$webroot/sub"

    aggregate_subscription
    install -m 644 "$SUB_FILE" "$webroot/sub/$token"

    # 复用已有域名时，不创建同名 server 块，避免抢占现有网站。
    if (( conflict )); then
        printf '订阅文件路径：%s\n' "$webroot/sub/$token"
        printf '预期 URL：https://%s/sub/%s\n' "$domain" "$token"
        warn "此 URL 只有在现有 HTTPS 站点允许访问该静态路径时才有效。"
        warn "如果访问失败，需根据现有 Nginx 路由调整，脚本不会自动改写原站点。"
        return 0
    fi

    # 无冲突时尝试申请证书。采用 standalone，不改动现有 Nginx 文件。
    # 若 80 端口已有服务，签发失败则安全回退。
    if [[ ! -s "$cert_file" || ! -s "$key_file" ]]; then
        if ! command -v certbot >/dev/null 2>&1; then
            apt-get install -y certbot || {
                warn "无法安装 Certbot，回退到本地订阅文件。"
                setup_local_subscription
                return 0
            }
        fi

        if port_in_use 80; then
            warn "80 端口已被占用，无法使用 standalone 自动签发证书。"
            warn "不会停止或抢占现有服务，回退到本地订阅文件。"
            setup_local_subscription
            return 0
        fi

        local email
        read -r -p "请输入证书通知邮箱（留空使用默认值）： " email || true

        local cert_args=(
            certonly --standalone
            --non-interactive
            --agree-tos
            --preferred-challenges http
            -d "$domain"
        )

        if [[ -n "$email" ]]; then
            cert_args+=(--email "$email")
        else
            cert_args+=(--register-unsafely-without-email)
        fi

        if ! certbot "${cert_args[@]}"; then
            warn "证书签发失败。检查域名 A 记录、云防火墙和 80 端口后重试。"
            setup_local_subscription
            return 0
        fi
    fi

    if [[ ! -s "$cert_file" || ! -s "$key_file" ]]; then
        warn "未找到有效证书文件，回退到本地订阅文件。"
        setup_local_subscription
        return 0
    fi

    # 再检查一次，防止部署过程中出现同域名站点。
    if nginx_domain_conflict "$domain"; then
        warn "配置期间检测到同域名站点出现，停止创建独立站点配置。"
        warn "不会覆盖现有配置，回退到本地订阅文件。"
        setup_local_subscription
        return 0
    fi

    cat > "$NGINX_CONF" <<EOF
server {
    listen 80;
    server_name $domain;

    location ^~ /.well-known/acme-challenge/ {
        root $WEB_ROOT;
        default_type text/plain;
        try_files \$uri =404;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl;
    server_name $domain;

    ssl_certificate $cert_file;
    ssl_certificate_key $key_file;

    root $WEB_ROOT;
    index index.html;

    location ^~ /sub/ {
        default_type text/plain;
        try_files \$uri =404;
    }

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF

    chmod 644 "$NGINX_CONF"
    ln -sfn "$NGINX_CONF" "$NGINX_LINK"

    if ! nginx -t; then
        warn "Nginx 配置测试失败，删除本脚本刚创建的配置。"
        rm -f "$NGINX_LINK" "$NGINX_CONF"
        setup_local_subscription
        return 0
    fi

    if ! systemctl enable --now nginx; then
        warn "Nginx 启动失败，删除本脚本创建的站点配置。"
        rm -f "$NGINX_LINK" "$NGINX_CONF"
        setup_local_subscription
        return 0
    fi

    if ! systemctl reload nginx; then
        warn "Nginx 重载失败，删除本脚本创建的站点配置。"
        rm -f "$NGINX_LINK" "$NGINX_CONF"
        nginx -t && systemctl reload nginx || true
        setup_local_subscription
        return 0
    fi

    printf 'HTTPS 订阅 URL：https://%s/sub/%s\n' "$domain" "$token"
}

deploy_reality() {
    local public_ip port uuid private_key public_key short_id sni name link
    local preferred_port=""

    public_ip="$(get_ipv4)" || {
        die "无法获取公网 IPv4 地址。请检查网络连接。"
        return 1
    }

    echo
    read -r -p "请输入节点名称 [默认 Reality-1]：" name || true
    name="${name:-Reality-1}"

    read -r -p "请输入监听端口 [默认随机]：" preferred_port || true

    port="$(random_free_port "$preferred_port")" || return 1

    if [[ -n "$preferred_port" && "$preferred_port" != "$port" ]]; then
        warn "指定端口不可用，已自动更换为：$port"
    fi

    uuid="$(cat /proc/sys/kernel/random/uuid)"
    sni="www.microsoft.com"
    short_id="$(openssl rand -hex 8)"

    local keys
    keys="$(generate_reality_keys)" || {
        die "生成 REALITY 密钥失败。"
        return 1
    }

    private_key="$(printf '%s\n' "$keys" | sed -n '1p')"
    public_key="$(printf '%s\n' "$keys" | sed -n '2p')"

    [[ -n "$private_key" && -n "$public_key" ]] || {
        die "REALITY 密钥为空。"
        return 1
    }

    write_xray_config "$port" "$uuid" "$private_key" "$short_id" "$sni"
    install_manager_service
    restart_manager_service

    link="$(make_reality_link "$name" "$public_ip" "$port" "$uuid" "$public_key" "$short_id" "$sni")"
    write_node_registry "$name" "$link"
    aggregate_subscription

    echo
    log "节点部署成功。"
    printf '节点名称：%s\n' "$name"
    printf '服务器 IPv4：%s\n' "$public_ip"
    printf '端口：%s\n' "$port"
    printf 'UUID：%s\n' "$uuid"
    printf 'SNI：%s\n' "$sni"
    printf 'Public Key：%s\n' "$public_key"
    printf 'Short ID：%s\n' "$short_id"
    echo
    printf 'VLESS 链接：\n%s\n' "$link"
    echo

    local mode domain token
    echo "订阅模式："
    echo "1. 不使用域名（默认）"
    echo "2. 域名 + HTTPS 订阅"
    read -r -p "请选择 [默认 1]：" mode || true
    mode="${mode:-1}"

    case "$mode" in
        2)
            read -r -p "请输入已解析到本机 IPv4 的域名：" domain || true
            token="$(create_token)"
            printf '%s\n' "$token" > "$TOKEN_FILE"
            chmod 600 "$TOKEN_FILE"
            setup_https_subscription "$domain" "$token"
            ;;
        *)
            setup_local_subscription
            ;;
    esac

    echo
    log "节点信息已保存。"
    log "配置文件：$XRAY_CONFIG"
    log "登记文件：$NODES_FILE"
    log "订阅文件：$SUB_FILE"
}

show_nodes() {
    echo
    if [[ ! -s "$NODES_FILE" ]]; then
        echo "当前没有登记节点。"
        return
    fi

    while IFS='|' read -r name link; do
        [[ -n "${name:-}" ]] || continue
        printf '\n名称：%s\n链接：%s\n' "$name" "${link:-}"
    done < "$NODES_FILE"
}

show_subscription() {
    aggregate_subscription
    echo
    cat "$SUB_FILE"
    echo
}

service_status() {
    systemctl status "$SERVICE_NAME" --no-pager || true
}

restart_service() {
    systemctl restart "$SERVICE_NAME" && log "服务已重启。" ||
        warn "服务重启失败，请查看日志。"
}

show_logs() {
    journalctl -u "$SERVICE_NAME" -n 80 --no-pager || true
}

install_shortcut() {
    local source="${BASH_SOURCE[0]}"

    if [[ "$source" != "$MANAGER_PATH" ]]; then
        install -m 755 "$source" "$MANAGER_PATH"
    fi

    cat > "$SHORTCUT_PATH" <<'EOF'
#!/usr/bin/env bash
exec /usr/local/bin/xiazheteng-node-manager.sh
EOF
    chmod 755 "$SHORTCUT_PATH"

    log "快捷启动已设置：在 SSH 中输入 x 即可打开菜单。"
}

uninstall_manager() {
    echo
    warn "此操作会删除本脚本管理的 Xray 实例和管理器文件。"
    warn "不会清空防火墙，也不会删除其他网站配置或系统级 Xray 配置。"

    read -r -p "确认卸载？输入 YES 继续：" confirm || true
    [[ "$confirm" == "YES" ]] || {
        echo "已取消。"
        return
    }

    systemctl disable --now "$SERVICE_NAME" >/dev/null 2>&1 || true
    rm -f "$SERVICE_FILE"
    systemctl daemon-reload

    # 仅删除本脚本登记的 Nginx 文件。
    rm -f "$NGINX_LINK" "$NGINX_CONF"
    if command -v nginx >/dev/null 2>&1; then
        nginx -t && systemctl reload nginx || true
    fi

    rm -f "$MANAGER_PATH" "$SHORTCUT_PATH"
    rm -rf "$BASE_DIR"

    echo "管理器已卸载。"
    echo "未卸载系统级 Xray，也未删除已有网站文件和证书。"
}

main_menu() {
    while true; do
        clear 2>/dev/null || true
        cat <<EOF
============================================================
       瞎折腾吧 | VPS 节点管理器 v${VERSION}
       IPv4-only | VLESS-REALITY
============================================================
1. 一键部署 VLESS-REALITY
2. 查看已登记节点
3. 查看统一订阅
4. 查看服务状态
5. 重启节点服务
6. 查看服务日志
7. 重新安装 x 快捷命令
8. 卸载本管理器
0. 退出
------------------------------------------------------------
输入 x 或 X 可返回主菜单
============================================================
EOF

        read -r -p "请选择：" choice || exit 0

        case "$choice" in
            1) deploy_reality; pause ;;
            2) show_nodes; pause ;;
            3) show_subscription; pause ;;
            4) service_status; pause ;;
            5) restart_service; pause ;;
            6) show_logs; pause ;;
            7) install_shortcut; pause ;;
            8) uninstall_manager; pause ;;
            0) exit 0 ;;
            x|X) continue ;;
            *) warn "无效选项。"; sleep 1 ;;
        esac
    done
}

main() {
    need_root || exit 1
    init_dirs

    if [[ ! -x /usr/local/bin/xray ]]; then
        install_packages
        install_xray
    fi

    install_shortcut
    main_menu
}

main "$@"
