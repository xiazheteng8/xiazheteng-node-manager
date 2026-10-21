
#!/usr/bin/env bash
# ============================================================
# 瞎折腾吧 | VPS 节点管理器
# 文件：xiazheteng-node-manager.sh
# GitHub: https://github.com/xiazheteng8/xiazheteng-node-manager
# YouTube: https://www.youtube.com/@xiazheteng8
# Telegram: https://t.me/xiazheteng8
#
# 默认无域名；选项 5 合并可识别的节点分享链接。
# SSH 登录后直接输入 x，即可启动管理器。
# ============================================================

set -Eeuo pipefail
umask 077

APP="xiazheteng-node-manager"
SCRIPT_NAME="xiazheteng-node-manager.sh"
GITHUB_RAW="https://raw.githubusercontent.com/xiazheteng8/xiazheteng-node-manager/main/xiazheteng-node-manager.sh"
UPSTREAM_URL="https://raw.githubusercontent.com/yonggekkk/sing-box-yg/main/sb.sh"

BASE="/etc/$APP"
CONF="$BASE/config"
DATA="$BASE/data"
BACKUP="$BASE/backups"

XRAY="/usr/local/bin/xray"
XRAY_CONFIG="$CONF/xray.json"
NODE_FILE="$DATA/node.txt"
SUB_FILE="$DATA/subscribe.txt"
SUB_URL_FILE="$DATA/subscribe_url"
TOKEN_FILE="$DATA/token"
DOMAIN_FILE="$DATA/domain"

SERVICE="xiazheteng-node-manager.service"
SERVICE_FILE="/etc/systemd/system/$SERVICE"
NGINX_SITE="/etc/nginx/conf.d/${APP}.conf"
WEB_ROOT="/var/www/$APP"
UPSTREAM="/opt/$APP/upstream/sb.sh"

info(){ printf '[信息] %s\n' "$*"; }
ok(){ printf '[成功] %s\n' "$*"; }
warn(){ printf '[注意] %s\n' "$*"; }
err(){ printf '[错误] %s\n' "$*" >&2; }
pause(){ echo; read -r -p "按回车键继续..." _; }
has(){ command -v "$1" >/dev/null 2>&1; }

require_root(){
    if [[ "$EUID" -ne 0 ]]; then
        err "请使用 root 用户运行。"
        exit 1
    fi
}

dirs(){
    install -d -m 700 "$BASE" "$CONF" "$DATA" "$BACKUP"
}

install_deps(){
    if has apt-get; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -y
        apt-get install -y curl ca-certificates openssl python3
    elif has dnf; then
        dnf install -y curl ca-certificates openssl python3
    elif has yum; then
        yum install -y curl ca-certificates openssl python3
    elif has apk; then
        apk add --no-cache curl ca-certificates openssl python3
    else
        err "无法识别系统包管理器。"
        return 1
    fi
}

# ============================================================
# SSH 快捷启动
# 自动创建：
#   /usr/local/bin/x
#   /usr/local/bin/xiazheteng-node-manager.sh
#   /etc/profile.d/xiazheteng-node-manager.sh
# ============================================================

install_shortcut(){
    local target="/usr/local/bin/$SCRIPT_NAME"
    local shortcut="/usr/local/bin/x"
    local source="${BASH_SOURCE[0]}"
    local tmp

    install -d -m 755 /usr/local/bin /etc/profile.d

    # 如果当前脚本是普通本地文件，优先安装当前文件。
    if [[ -f "$source" && "$source" != /dev/fd/* ]]; then
        if ! install -m 755 "$source" "$target"; then
            warn "无法复制当前脚本到 $target"
            return 1
        fi
    else
        # bash <(curl ...) 方式运行时，从仓库下载持久脚本。
        tmp="$(mktemp)"
        if ! curl -fsSL --retry 3 --connect-timeout 10 \
            "$GITHUB_RAW" -o "$tmp"; then
            rm -f "$tmp"
            warn "无法下载 GitHub 脚本，未能安装持久入口。"
            warn "请先将完整脚本提交到指定 GitHub 仓库后重新运行。"
            return 1
        fi

        if ! bash -n "$tmp"; then
            rm -f "$tmp"
            warn "下载的脚本语法检查失败，取消安装快捷入口。"
            return 1
        fi

        install -m 755 "$tmp" "$target"
        rm -f "$tmp"
    fi

    cat > "$shortcut" <<'EOF'
#!/usr/bin/env bash
SCRIPT="/usr/local/bin/xiazheteng-node-manager.sh"

if [[ ! -f "$SCRIPT" ]]; then
    echo "[错误] 找不到管理器脚本：$SCRIPT"
    exit 1
fi

exec /usr/bin/env bash "$SCRIPT" "$@"
EOF
    chmod 755 "$shortcut"

    # 登录 Shell 的 PATH 兜底配置。
    cat > /etc/profile.d/xiazheteng-node-manager.sh <<'EOF'
case ":$PATH:" in
    *:/usr/local/bin:*) ;;
    *) export PATH="/usr/local/bin:$PATH" ;;
esac
EOF
    chmod 644 /etc/profile.d/xiazheteng-node-manager.sh

    # 当前 Shell 也立即生效。
    export PATH="/usr/local/bin:$PATH"

    ok "SSH 快捷命令 x 已安装。"
}

public_ip(){
    local ip=""
    ip="$(curl -4 -fsS --max-time 8 https://api.ipify.org 2>/dev/null || true)"
    if [[ -z "$ip" ]]; then
        ip="$(curl -4 -fsS --max-time 8 https://ifconfig.me/ip 2>/dev/null || true)"
    fi
    printf '%s' "$ip"
}

port_used(){
    local p="$1"
    if has ss; then
        ss -H -lntu 2>/dev/null |
            awk '{print $5}' |
            grep -Eq "[:.]${p}$"
    else
        return 1
    fi
}

random_port(){
    python3 - <<'PY'
import secrets
print(secrets.randbelow(40000) + 20000)
PY
}

free_port(){
    local i p
    for i in $(seq 1 100); do
        p="$(random_port)"
        if ! port_used "$p"; then
            printf '%s\n' "$p"
            return 0
        fi
    done
    err "无法找到未被本机监听的端口。"
    return 1
}

install_xray(){
    if [[ -x "$XRAY" ]]; then
        info "Xray 已安装：$("$XRAY" version 2>/dev/null | head -n 1 || true)"
        return 0
    fi

    local tmp
    tmp="$(mktemp)"

    if ! curl -fL --retry 3 \
        https://github.com/XTLS/Xray-install/raw/main/install-release.sh \
        -o "$tmp"; then
        rm -f "$tmp"
        err "下载 Xray 安装脚本失败。"
        return 1
    fi

    if ! bash "$tmp" install; then
        rm -f "$tmp"
        err "Xray 安装失败。"
        return 1
    fi

    rm -f "$tmp"

    if [[ ! -x "$XRAY" ]]; then
        err "安装结束，但未找到 $XRAY"
        return 1
    fi
}

# 兼容常见 Xray 密钥输出字段。
# 无法可靠提取时停止，不把私钥冒充公钥。
reality_keys(){
    local output priv pub

    output="$("$XRAY" x25519 2>&1)" || {
        err "Xray x25519 执行失败："
        printf '%s\n' "$output"
        return 1
    }

    priv="$(printf '%s\n' "$output" |
        awk -F': *' '
        tolower($1) ~ /privatekey|private key/ {
            print $2; exit
        }')"

    pub="$(printf '%s\n' "$output" |
        awk -F': *' '
        tolower($1) ~ /^(password|publickey|public key)$/ {
            print $2; exit
        }')"

    if [[ -z "$priv" || -z "$pub" ]]; then
        err "无法识别当前 Xray 的密钥输出格式。"
        printf '%s\n' "$output"
        return 1
    fi

    printf '%s\n%s\n' "$priv" "$pub"
}

make_vless(){
    local uuid="$1" host="$2" port="$3" pub="$4" sid="$5"

    python3 - "$uuid" "$host" "$port" "$pub" "$sid" <<'PY'
import sys
from urllib.parse import quote

uid, host, port, pub, sid = sys.argv[1:]

if ":" in host and not host.startswith("["):
    host = "[" + host + "]"

print(
    f"vless://{uid}@{host}:{port}"
    f"?encryption=none&security=reality"
    f"&sni=www.microsoft.com&fp=chrome"
    f"&pbk={quote(pub, safe='')}"
    f"&sid={quote(sid, safe='')}"
    f"&type=tcp&flow=xtls-rprx-vision"
    f"#Xiazheteng-REALITY"
)
PY
}

write_xray_config(){
    local uuid="$1" port="$2" priv="$3" sid="$4"

    python3 - "$XRAY_CONFIG" "$uuid" "$port" "$priv" "$sid" <<'PY'
import json, sys

path, uid, port, private_key, short_id = sys.argv[1:]
cfg = {
    "log": {"loglevel": "warning"},
    "inbounds": [{
        "listen": "0.0.0.0",
        "port": int(port),
        "protocol": "vless",
        "settings": {
            "clients": [{
                "id": uid,
                "flow": "xtls-rprx-vision"
            }],
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
    json.dump(cfg, f, indent=2)
    f.write("\n")
PY
    chmod 600 "$XRAY_CONFIG"
}

write_service(){
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Xiazheteng Node Manager Xray Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$XRAY run -config $XRAY_CONFIG
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "$SERVICE" >/dev/null
}

encode_file(){
    local source="$1" destination="$2"

    if [[ ! -s "$source" ]]; then
        err "订阅源文件为空：$source"
        return 1
    fi

    base64 < "$source" | tr -d '\n' > "$destination"
    printf '\n' >> "$destination"
    chmod 600 "$destination"
}

open_local_port(){
    local p="$1"

    if has ufw && ufw status 2>/dev/null | grep -q 'Status: active'; then
        ufw allow "$p/tcp" || true
    elif has firewall-cmd && systemctl is-active --quiet firewalld; then
        firewall-cmd --permanent --add-port="${p}/tcp" || true
        firewall-cmd --reload || true
    else
        info "未自动修改本机防火墙。"
    fi

    warn "还需检查云厂商安全组是否放行 TCP $p。"
}

validate_domain(){
    [[ "$1" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,}$ ]]
}

setup_nginx_packages(){
    if has nginx; then return 0; fi

    if has apt-get; then
        apt-get install -y nginx
    elif has dnf; then
        dnf install -y nginx
    elif has yum; then
        yum install -y nginx
    else
        err "无法自动安装 Nginx。"
        return 1
    fi
}

setup_certbot(){
    if has certbot; then return 0; fi

    if has apt-get; then
        apt-get install -y certbot python3-certbot-nginx
    elif has dnf; then
        dnf install -y certbot python3-certbot-nginx ||
            dnf install -y certbot
    elif has yum; then
        yum install -y certbot python3-certbot-nginx ||
            yum install -y certbot
    else
        err "请手动安装 Certbot。"
        return 1
    fi
}

publish_subscription(){
    local domain="$1"
    local token pubip dnsip url

    validate_domain "$domain" || {
        err "域名格式不正确。"
        return 1
    }

    setup_nginx_packages || return 1

    pubip="$(public_ip)"
    dnsip="$(getent ahostsv4 "$domain" 2>/dev/null |
        awk 'NR==1 {print $1}')"

    if [[ -z "$pubip" || -z "$dnsip" || "$pubip" != "$dnsip" ]]; then
        err "域名解析未指向当前服务器 IPv4。"
        echo "服务器公网 IP：${pubip:-未知}"
        echo "域名解析 IP：${dnsip:-未知}"
        return 1
    fi

    if [[ -e "$NGINX_SITE" ]]; then
        err "已有管理器 Nginx 配置，拒绝覆盖：$NGINX_SITE"
        return 1
    fi

    token="$(openssl rand -hex 24)"
    install -d -m 755 "$WEB_ROOT/sub"
    install -m 644 "$SUB_FILE" "$WEB_ROOT/sub/$token"

    cat > "$NGINX_SITE" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $domain;

    location = /sub/$token {
        default_type text/plain;
        alias $WEB_ROOT/sub/$token;
        add_header Cache-Control "no-store";
    }

    location / {
        return 404;
    }
}
EOF

    if ! nginx -t; then
        rm -f "$NGINX_SITE"
        err "Nginx 配置校验失败。"
        return 1
    fi

    systemctl enable --now nginx
    systemctl reload nginx

    setup_certbot || return 1

    if ! certbot --nginx -d "$domain" \
        --non-interactive --agree-tos \
        --register-unsafely-without-email --redirect; then
        err "HTTPS 证书申请失败。"
        return 1
    fi

    nginx -t || return 1
    systemctl reload nginx

    url="https://$domain/sub/$token"

    if ! curl -fsS --connect-timeout 8 --max-time 15 \
        "$url" -o /dev/null; then
        err "订阅 URL 未通过 HTTPS 可访问性检查。"
        return 1
    fi

    printf '%s\n' "$token" > "$TOKEN_FILE"
    printf '%s\n' "$domain" > "$DOMAIN_FILE"
    printf '%s\n' "$url" > "$SUB_URL_FILE"
    chmod 600 "$TOKEN_FILE" "$DOMAIN_FILE" "$SUB_URL_FILE"

    printf '%s\n' "$url"
}

install_node(){
    require_root
    install_deps
    dirs
    install_xray

    echo
    echo "请选择订阅模式："
    echo "1. 域名 + HTTPS 订阅"
    echo "2. 不使用域名（默认）"
    read -r -p "请选择 [默认 2]：" mode
    mode="${mode:-2}"

    [[ "$mode" == 1 || "$mode" == 2 ]] || {
        err "无效选项。"
        return 1
    }

    local domain=""
    if [[ "$mode" == 1 ]]; then
        read -r -p "请输入已解析到本机的域名：" domain
        [[ -n "$domain" ]] || {
            err "域名不能为空。"
            return 1
        }
    fi

    local port uuid sid keys priv pub host uri
    port="$(free_port)"
    uuid="$(cat /proc/sys/kernel/random/uuid)"
    sid="$(openssl rand -hex 8)"

    keys="$(reality_keys)" || return 1
    priv="$(printf '%s\n' "$keys" | sed -n '1p')"
    pub="$(printf '%s\n' "$keys" | sed -n '2p')"

    write_xray_config "$uuid" "$port" "$priv" "$sid"

    if ! "$XRAY" run -test -config "$XRAY_CONFIG"; then
        err "Xray 配置校验失败，未启动服务。"
        return 1
    fi

    write_service
    systemctl restart "$SERVICE"
    sleep 2

    if ! systemctl is-active --quiet "$SERVICE"; then
        err "Xray 服务启动失败。"
        journalctl -u "$SERVICE" -n 60 --no-pager || true
        return 1
    fi

    host="$(public_ip)"
    if [[ -z "$host" ]]; then
        read -r -p "无法自动获取公网 IP，请输入节点地址：" host
    fi

    [[ -n "$host" ]] || {
        err "节点地址不能为空。"
        return 1
    }

    uri="$(make_vless "$uuid" "$host" "$port" "$pub" "$sid")"
    printf '%s\n' "$uri" > "$NODE_FILE"
    encode_file "$NODE_FILE" "$SUB_FILE"
    open_local_port "$port"

    echo
    ok "节点配置检查通过，服务正在运行。"
    echo "节点连接："
    cat "$NODE_FILE"
    echo
    echo "本地 Base64 订阅文件：$SUB_FILE"

    if [[ "$mode" == 1 ]]; then
        local url
        if url="$(publish_subscription "$domain")"; then
            echo
            ok "HTTPS 订阅地址："
            echo "$url"
        else
            warn "公网订阅未验证成功，请检查 DNS、80/443 端口及证书。"
        fi
    else
        echo
        echo "Base64 订阅内容："
        cat "$SUB_FILE"
    fi

    echo
    warn "请在云厂商安全组中放行 TCP $port。"
    warn "本机服务正常不代表公网端口一定可达。"
}

# ============================================================
# 订阅扫描
# 扫描常见目录中的分享链接，并尝试转换部分 Xray 配置。
# 无法确认公钥或连接参数的配置会跳过，避免生成伪链接。
# ============================================================

scan_share_file(){
    local f="$1"
    [[ -r "$f" ]] || return 0

    grep -Eo \
      '(vless|vmess|trojan|ss|ssr|hysteria|hysteria2|tuic|wireguard)://[^[:space:]"<>]+' \
      "$f" 2>/dev/null || true
}

scan_json_config(){
    local f="$1"
    [[ -r "$f" ]] || return 0

    python3 - "$f" <<'PY'
import json, sys
from urllib.parse import urlencode, quote

try:
    with open(sys.argv[1], encoding="utf-8") as fp:
        cfg = json.load(fp)
except Exception:
    sys.exit(0)

for ib in cfg.get("inbounds", []):
    try:
        port = ib.get("port")
        proto = str(ib.get("protocol", "")).lower()
        settings = ib.get("settings", {})
        stream = ib.get("streamSettings", {})
        network = stream.get("network", "tcp")
        security = stream.get("security", "none")
        host = ib.get("listen", "")

        # 监听地址不是客户端公网地址时，不能拿来生成连接链接。
        if not host or host in (
            "0.0.0.0", "::", "[::]", "localhost", "127.0.0.1"
        ):
            continue
        if not port:
            continue

        if proto == "vless" and security != "reality":
            for client in settings.get("clients", []):
                uid = client.get("id")
                if not uid:
                    continue

                params = {
                    "encryption": "none",
                    "type": network,
                    "security": security
                }

                flow = client.get("flow")
                if flow:
                    params["flow"] = flow

                if security == "tls":
                    tls = stream.get("tlsSettings", {})
                    if tls.get("serverName"):
                        params["sni"] = tls["serverName"]

                print(
                    f"vless://{uid}@{host}:{port}?"
                    f"{urlencode(params)}#scanned-vless"
                )

        elif proto == "trojan":
            for client in settings.get("clients", []):
                password = client.get("password")
                if not password:
                    continue

                params = {"type": network, "security": security}
                if security == "tls":
                    tls = stream.get("tlsSettings", {})
                    if tls.get("serverName"):
                        params["sni"] = tls["serverName"]

                print(
                    f"trojan://{quote(password, safe='')}@{host}:{port}?"
                    f"{urlencode(params)}#scanned-trojan"
                )
    except Exception:
        continue
PY
}

discover_files(){
    local roots=(
        /usr/local/etc/xray
        /usr/local/etc/v2ray
        /etc/xray
        /etc/v2ray
        /etc/sing-box
        /usr/local/etc/sing-box
        /opt
    )

    local d
    for d in "${roots[@]}"; do
        [[ -d "$d" ]] || continue
        find "$d" -maxdepth 5 -type f \
            \( -name '*.json' -o -name '*.txt' -o -name '*.conf' \) \
            -not -path "$BASE/*" -print 2>/dev/null || true
    done | sort -u
}

subscribe_all(){
    require_root
    dirs

    echo
    echo "请选择订阅模式："
    echo "1. 域名 + HTTPS 订阅"
    echo "2. 不使用域名（默认）"
    read -r -p "请选择 [默认 2]：" mode
    mode="${mode:-2}"

    [[ "$mode" == 1 || "$mode" == 2 ]] || {
        err "无效选项。"
        return 1
    }

    local domain=""
    if [[ "$mode" == 1 ]]; then
        read -r -p "请输入已解析到本机的域名：" domain
        [[ -n "$domain" ]] && validate_domain "$domain" || {
            err "域名为空或格式错误。"
            return 1
        }
    fi

    local tmp f merged count
    tmp="$(mktemp)"
    merged="$DATA/all-nodes.txt"

    # 本管理器生成的节点。
    [[ -r "$NODE_FILE" ]] && cat "$NODE_FILE" >> "$tmp"

    # 从常见配置目录扫描分享链接。
    while IFS= read -r f; do
        case "$f" in
            *.txt|*.conf)
                scan_share_file "$f" >> "$tmp"
                ;;
            *.json)
                scan_json_config "$f" >> "$tmp"
                ;;
        esac
    done < <(discover_files)

    grep -E \
      '^(vless|vmess|trojan|ss|ssr|hysteria|hysteria2|tuic|wireguard)://' \
      "$tmp" | sed 's/\r$//' | sort -u > "$merged" || true

    rm -f "$tmp"

    count="$(grep -c . "$merged" 2>/dev/null || true)"
    count="${count:-0}"

    if [[ "$count" -eq 0 ]]; then
        err "没有发现可直接导入的节点分享链接。"
        warn "某些服务端配置缺少客户端地址或公钥，不能仅凭配置文件可靠生成分享链接。"
        return 1
    fi

    encode_file "$merged" "$SUB_FILE"

    ok "订阅合并完成，共 $count 条去重分享链接。"
    echo "节点清单：$merged"
    echo "Base64 订阅文件：$SUB_FILE"

    if [[ "$mode" == 1 ]]; then
        local url
        if url="$(publish_subscription "$domain")"; then
            echo
            ok "HTTPS 订阅地址："
            echo "$url"
        else
            err "公网订阅未通过检查；本地订阅文件仍已生成。"
            return 1
        fi
    else
        echo
        echo "Base64 订阅内容："
        cat "$SUB_FILE"
        echo
        warn "无域名模式不会生成公网 HTTPS 订阅地址。"
    fi
}

show_status(){
    echo
    systemctl --no-pager -l status "$SERVICE" 2>/dev/null || true
    if [[ -x "$XRAY" ]]; then
        "$XRAY" version 2>/dev/null | head -n 3
    fi
}

restart_xray(){
    if systemctl restart "$SERVICE"; then
        ok "服务已重启。"
    else
        err "服务重启失败。"
        journalctl -u "$SERVICE" -n 50 --no-pager || true
    fi
}

show_logs(){
    journalctl -u "$SERVICE" -n 100 --no-pager || true
}

update_xray(){
    local tmp rc
    tmp="$(mktemp)"

    if ! curl -fL --retry 3 \
        https://github.com/XTLS/Xray-install/raw/main/install-release.sh \
        -o "$tmp"; then
        rm -f "$tmp"
        err "下载更新脚本失败。"
        return 1
    fi

    bash "$tmp" install
    rc=$?
    rm -f "$tmp"
    return "$rc"
}

backup_config(){
    dirs
    local file="$BACKUP/backup-$(date +%Y%m%d-%H%M%S).tar.gz"
    tar -czf "$file" -C "$BASE" config data
    chmod 600 "$file"
    ok "备份完成：$file"
}

show_node(){
    if [[ -r "$NODE_FILE" ]]; then
        cat "$NODE_FILE"
    else
        warn "本管理器尚未生成节点。"
    fi
}

check_ports(){
    if has ss; then
        ss -lntup
    else
        warn "系统缺少 ss 命令。"
    fi
}

kernel_menu(){
    while true; do
        echo
        echo "========== 内核与服务管理 =========="
        echo "1. 查看服务状态"
        echo "2. 重启 Xray 服务"
        echo "3. 查看服务日志"
        echo "4. 更新 Xray"
        echo "5. 查看本管理器节点"
        echo "6. 备份配置"
        echo "7. 检查监听端口"
        echo "0. 返回主菜单"

        read -r -p "请选择：" c
        case "$c" in
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

install_upstream(){
    install -d -m 700 "$(dirname "$UPSTREAM")"

    local tmp
    tmp="$(mktemp)"

    if ! curl -fL --retry 3 "$UPSTREAM_URL" -o "$tmp"; then
        rm -f "$tmp"
        err "下载勇哥脚本失败。"
        return 1
    fi

    if ! head -n 1 "$tmp" | grep -q '^#!'; then
        rm -f "$tmp"
        err "下载内容不是预期的 Shell 脚本。"
        return 1
    fi

    install -m 700 "$tmp" "$UPSTREAM"
    rm -f "$tmp"
    ok "已保存上游脚本：$UPSTREAM"
}

run_upstream(){
    if [[ ! -x "$UPSTREAM" ]]; then
        install_upstream || return 1
    fi

    warn "即将以 root 权限运行第三方脚本。"
    read -r -p "确定运行？[y/N]：" c

    if [[ "$c" == y || "$c" == Y ]]; then
        bash "$UPSTREAM"
    fi
}

show_subscription(){
    if [[ -r "$SUB_FILE" ]]; then
        cat "$SUB_FILE"
    else
        warn "尚无订阅文件。"
    fi

    if [[ -r "$SUB_URL_FILE" ]]; then
        echo
        echo "已记录的公网订阅地址："
        cat "$SUB_URL_FILE"
    fi
}

enable_bbr(){
    touch /etc/sysctl.conf

    grep -q '^net.core.default_qdisc=fq$' /etc/sysctl.conf ||
        echo 'net.core.default_qdisc=fq' >> /etc/sysctl.conf

    grep -q '^net.ipv4.tcp_congestion_control=bbr$' /etc/sysctl.conf ||
        echo 'net.ipv4.tcp_congestion_control=bbr' >> /etc/sysctl.conf

    sysctl -p
}

check_https(){
    if [[ -r "$SUB_URL_FILE" ]]; then
        curl -fsS -D - --connect-timeout 8 --max-time 15 \
            "$(cat "$SUB_URL_FILE")" -o /dev/null
    else
        warn "没有已验证的 HTTPS 订阅地址。"
    fi
}

update_manager(){
    local tmp
    tmp="$(mktemp)"

    if ! curl -fL --retry 3 "$GITHUB_RAW" -o "$tmp"; then
        rm -f "$tmp"
        err "下载管理器更新失败。"
        return 1
    fi

    if ! bash -n "$tmp"; then
        rm -f "$tmp"
        err "新脚本语法检查失败，取消更新。"
        return 1
    fi

    install -m 755 "$tmp" "/usr/local/bin/$SCRIPT_NAME"
    rm -f "$tmp"
    ok "管理器已更新。"
}

more_menu(){
    while true; do
        echo
        echo "========== 更多功能 =========="
        echo "1. 打开勇哥 Sing-box 菜单"
        echo "2. 下载/更新勇哥脚本"
        echo "3. 查看 Base64 订阅"
        echo "4. 开启 BBR"
        echo "5. 检查 HTTPS 订阅"
        echo "6. 更新本管理器"
        echo "0. 返回主菜单"

        read -r -p "请选择：" c
        case "$c" in
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

uninstall_manager(){
    echo
    warn "将删除本管理器服务与配置，不会卸载全局 Xray 或 Nginx。"
    read -r -p "输入 DELETE 确认卸载：" c

    [[ "$c" == DELETE ]] || {
        info "已取消。"
        return
    }

    systemctl disable --now "$SERVICE" >/dev/null 2>&1 || true
    rm -f "$SERVICE_FILE"

    if [[ -f "$NGINX_SITE" ]] && grep -q "$WEB_ROOT" "$NGINX_SITE"; then
        rm -f "$NGINX_SITE"
        if nginx -t >/dev/null 2>&1; then
            systemctl reload nginx >/dev/null 2>&1 || true
        fi
    fi

    rm -rf "$BASE" "$WEB_ROOT" "/opt/$APP"
    systemctl daemon-reload

    warn "不会自动删除系统中其他站点或证书。"
    read -r -p "是否删除快捷命令 x 和管理器入口？[y/N]：" c

    if [[ "$c" == y || "$c" == Y ]]; then
        rm -f /usr/local/bin/x
        rm -f "/usr/local/bin/$SCRIPT_NAME"
        rm -f /etc/profile.d/xiazheteng-node-manager.sh
    fi

    ok "管理器清理完成。"
}

main_menu(){
    while true; do
        clear 2>/dev/null || true

        echo "=================================================="
        echo "          瞎折腾吧 | VPS 节点管理器"
        echo "=================================================="
        echo "1. 一键安装"
        echo "2. 一键卸载"
        echo "3. 内核与服务管理"
        echo "4. 更多功能"
        echo "5. 一键订阅所有已安装节点"
        echo
        echo "输入 x / X：启动管理器快捷入口"
        echo "输入 q / Q：退出"
        echo "=================================================="

        read -r -p "请输入选项：" c

        case "$c" in
            1) install_node; pause ;;
            2) uninstall_manager; pause ;;
            3) kernel_menu ;;
            4) more_menu ;;
            5) subscribe_all; pause ;;
            x|X)
                install_shortcut || true
                echo
                info "当前已经在管理器中。"
                info "以后 SSH 登录后，可直接输入 x 启动。"
                pause
                ;;
            q|Q) exit 0 ;;
            *) warn "无效选项。"; sleep 1 ;;
        esac
    done
}

main(){
    require_root
    dirs

    # 每次启动都检查快捷命令，避免入口丢失。
    install_shortcut || warn "快捷命令自动安装失败；主菜单仍可继续使用。"

    main_menu
}

main "$@"
