#!/usr/bin/env bash
# ============================================================
# 瞎折腾吧 | VPS 节点管理器
# GitHub:   https://github.com/xiazheteng8/xiazheteng-node-manager
# YouTube:  https://www.youtube.com/@xiazheteng8
# Telegram: https://t.me/xiazheteng8
#
# 单文件统一管理入口
# - IPv4-only
# - VLESS-REALITY 一键部署
# - 可选 HTTPS 订阅
# - 无域名模式为默认选项
# - 节点订阅聚合与去重
# - x / X 快捷启动
# - 独立 Xray 配置和 systemd 服务
# - 不清空防火墙规则
# - 不覆盖其他网站配置
# ============================================================

set -Eeuo pipefail
umask 077

APP_NAME="xiazheteng-node-manager"
APP_TITLE="瞎折腾吧 | VPS 节点管理器"
GITHUB_RAW="https://raw.githubusercontent.com/xiazheteng8/xiazheteng-node-manager/main/xiazheteng-node-manager.sh"

BASE_DIR="/etc/${APP_NAME}"
CONFIG_DIR="${BASE_DIR}/config"
DATA_DIR="${BASE_DIR}/data"
XRAY_CONFIG="${CONFIG_DIR}/xray.json"
NODES_FILE="${DATA_DIR}/nodes.txt"
SETTINGS_FILE="${BASE_DIR}/settings"
TOKEN_FILE="${BASE_DIR}/subscription-token"

MANAGER_PATH="/usr/local/bin/${APP_NAME}.sh"
SHORTCUT_PATH="/usr/local/bin/x"

XRAY="/usr/local/bin/xray"
SERVICE_NAME="${APP_NAME}.service"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}"

NGINX_ROOT="/var/www/html"
SUB_DIR="${NGINX_ROOT}/sub"
NGINX_CONF="/etc/nginx/sites-available/${APP_NAME}.conf"
NGINX_LINK="/etc/nginx/sites-enabled/${APP_NAME}.conf"

mkdir -p "$CONFIG_DIR" "$DATA_DIR"
touch "$NODES_FILE"

info() { printf '\033[1;34m[信息]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[成功]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[提示]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[错误]\033[0m %s\n' "$*" >&2; }

pause() {
    echo
    read -r -p "按回车键继续..." _ || true
}

need_root() {
    if [[ "$EUID" -ne 0 ]]; then
        err "请使用 root 权限运行。"
        exit 1
    fi
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

install_packages() {
    if ! command_exists apt-get; then
        err "自动安装目前仅支持 Debian / Ubuntu。"
        return 1
    fi

    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y \
        curl ca-certificates unzip openssl \
        python3 nginx certbot iproute2 \
        coreutils util-linux
}

# ============================================================
# IPv4 网络
# ============================================================

get_public_ip() {
    local ip=""

    ip="$(curl -4 -fsS --max-time 8 https://api.ipify.org 2>/dev/null || true)"
    ip="${ip//[$'\r\n\t ']/}"

    if [[ ! "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        ip="$(curl -4 -fsS --max-time 8 https://ipv4.icanhazip.com 2>/dev/null || true)"
        ip="${ip//[$'\r\n\t ']/}"
    fi

    if [[ ! "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        err "无法获取公网 IPv4。"
        return 1
    fi

    python3 - "$ip" <<'PY'
import ipaddress
import sys

try:
    addr = ipaddress.IPv4Address(sys.argv[1])
    if not addr.is_global:
        raise ValueError("不是可用的公网 IPv4")
    print(addr)
except Exception as exc:
    print(f"[错误] IPv4 地址无效：{exc}", file=sys.stderr)
    sys.exit(1)
PY
}

port_in_use() {
    local port="$1"
    ss -H -lnt 2>/dev/null |
        awk '{print $4}' |
        grep -Eq "[:.]${port}$"
}

random_port() {
    local port tries=0

    while (( tries < 200 )); do
        port="$(shuf -i 20000-60000 -n 1)"

        if ! port_in_use "$port"; then
            printf '%s\n' "$port"
            return 0
        fi

        tries=$((tries + 1))
    done

    err "找不到空闲端口。"
    return 1
}

# ============================================================
# 快捷命令 x
# ============================================================

install_shortcut() {
    local source_path=""

    if [[ -f "${BASH_SOURCE[0]}" &&
          "${BASH_SOURCE[0]}" != /dev/fd/* ]]; then
        source_path="$(readlink -f "${BASH_SOURCE[0]}")"

        if [[ "$source_path" != "$MANAGER_PATH" ]]; then
            install -m 755 "$source_path" "$MANAGER_PATH"
        fi
    elif [[ ! -x "$MANAGER_PATH" ]]; then
        info "正在下载管理器持久脚本..."

        if curl -fLsS --retry 2 --connect-timeout 10 \
            "$GITHUB_RAW" -o "${MANAGER_PATH}.tmp"; then

            if bash -n "${MANAGER_PATH}.tmp"; then
                install -m 755 "${MANAGER_PATH}.tmp" "$MANAGER_PATH"
                rm -f "${MANAGER_PATH}.tmp"
            else
                rm -f "${MANAGER_PATH}.tmp"
                warn "下载的脚本语法检查失败。"
            fi
        else
            rm -f "${MANAGER_PATH}.tmp"
            warn "无法下载持久脚本。"
        fi
    fi

    if [[ -f "$MANAGER_PATH" ]]; then
        cat > "$SHORTCUT_PATH" <<'SHORTCUT'
#!/usr/bin/env bash
exec bash /usr/local/bin/xiazheteng-node-manager.sh "$@"
SHORTCUT
        chmod 755 "$SHORTCUT_PATH"
        ok "快捷入口已配置，输入 x 即可启动。"
    fi
}

# ============================================================
# Xray 安装
# ============================================================

install_xray() {
    if [[ -x "$XRAY" ]]; then
        ok "已安装 Xray：$("$XRAY" version 2>/dev/null | head -n 1 || true)"
        return 0
    fi

    install_packages
    info "正在安装 Xray..."

    bash -c "$(curl -fsSL \
        https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

    if [[ ! -x "$XRAY" ]]; then
        err "安装后未找到 $XRAY。"
        return 1
    fi

    ok "Xray 安装完成。"
}

# ============================================================
# REALITY 密钥解析
# ============================================================

reality_keys() {
    local output

    output="$("$XRAY" x25519 2>&1)" || {
        err "Xray 密钥生成失败。"
        printf '%s\n' "$output" >&2
        return 1
    }

    python3 -c '
import re
import sys

text = sys.stdin.read()
fields = {}

for line in text.splitlines():
    if ":" not in line:
        continue

    label, value = line.split(":", 1)
    label = re.sub(r"[^a-z]", "", label.lower())
    value = value.strip()

    if value:
        fields[label] = value

private_key = (
    fields.get("privatekey")
    or fields.get("private")
    or ""
)

# 部分 Xray 版本会把公钥标记为 Password。
public_key = (
    fields.get("passwordpublickey")
    or fields.get("publickey")
    or fields.get("public")
    or fields.get("password")
    or ""
)

if not private_key or not public_key:
    print("[错误] 无法识别 Xray 密钥输出格式。", file=sys.stderr)
    print("识别字段：" + ", ".join(fields.keys()), file=sys.stderr)
    print(text, file=sys.stderr)
    sys.exit(1)

if private_key == public_key:
    print("[错误] 私钥与公钥相同，拒绝继续。", file=sys.stderr)
    sys.exit(1)

print(private_key)
print(public_key)
' <<< "$output"
}

# ============================================================
# 分享链接生成
# ============================================================

make_reality_link() {
    local ip="$1"
    local port="$2"
    local uuid="$3"
    local public_key="$4"
    local sid="$5"
    local remark="$6"

    python3 - "$ip" "$port" "$uuid" "$public_key" "$sid" "$remark" <<'PY'
import ipaddress
import sys
from urllib.parse import quote

ip, port, uid, pbk, sid, remark = sys.argv[1:]
ip = str(ipaddress.IPv4Address(ip))
port = int(port)

if not 1 <= port <= 65535:
    raise SystemExit("端口无效")

params = (
    "encryption=none"
    "&flow=xtls-rprx-vision"
    "&security=reality"
    "&sni=www.microsoft.com"
    "&fp=chrome"
    f"&pbk={quote(pbk, safe='')}"
    f"&sid={quote(sid, safe='')}"
    "&type=tcp"
)

print(
    f"vless://{uid}@{ip}:{port}?{params}"
    f"#{quote(remark, safe='')}"
)
PY
}

# ============================================================
# 域名校验
# ============================================================

validate_domain() {
    python3 - "$1" <<'PY'
import re
import sys

domain = sys.argv[1].rstrip(".").lower()

if len(domain) > 253:
    raise SystemExit(1)

labels = domain.split(".")

if len(labels) < 2:
    raise SystemExit(1)

for label in labels:
    if len(label) > 63:
        raise SystemExit(1)
    if not re.fullmatch(r"[a-z0-9](?:[a-z0-9-]*[a-z0-9])?", label):
        raise SystemExit(1)

print(domain)
PY
}

# ============================================================
# HTTPS 订阅配置
# ============================================================

configure_https_subscription() {
    local domain email token

    echo
    read -r -p "请输入已解析到本机 IPv4 的域名：" domain

    domain="${domain,,}"
    domain="${domain%.}"

    if ! domain="$(validate_domain "$domain")"; then
        err "域名格式不正确。"
        return 1
    fi

    read -r -p "请输入证书申请邮箱：" email

    if [[ ! "$email" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]]; then
        err "邮箱格式不正确。"
        return 1
    fi

    install_packages

    if [[ -e "$NGINX_CONF" || -e "$NGINX_LINK" ]]; then
        err "本项目的 Nginx 配置已存在，为避免覆盖，停止本次操作。"
        return 1
    fi

    # 如果域名已被其他站点占用，不覆盖原站点。
    # 同域名不能通过随意创建第二个 server 块来保证订阅正常。
    if grep -RqsE \
        "server_name[[:space:]]+[^;]*${domain//./\\.}([[:space:];]|$)" \
        /etc/nginx/sites-enabled /etc/nginx/conf.d 2>/dev/null; then

        err "检测到此域名可能已被其他 Nginx 站点使用。"
        warn "为保护现有网站，本脚本不会覆盖或改写该站点。"
        warn "请使用尚未被 Nginx 使用的域名或子域名后重试。"
        return 1
    fi

    mkdir -p "$NGINX_ROOT" "$SUB_DIR"
    chmod 755 "$NGINX_ROOT" "$SUB_DIR"

    systemctl enable --now nginx

    if ! DOMAIN="$domain" python3 - <<'PY'
import os
import socket
import sys

domain = os.environ["DOMAIN"]

try:
    answers = socket.getaddrinfo(
        domain, 80, socket.AF_INET, socket.SOCK_STREAM
    )
    ips = {x[4][0] for x in answers}

    if not ips:
        raise RuntimeError("没有 IPv4 解析结果")

    for ip in sorted(ips):
        print("解析到 IPv4：", ip)

except Exception as exc:
    print("域名 IPv4 检查失败：", exc, file=sys.stderr)
    sys.exit(1)
PY
    then
        err "请先配置域名 A 记录并确认解析正确。"
        return 1
    fi

    mkdir -p "$NGINX_ROOT/.well-known/acme-challenge"

    info "正在申请 HTTPS 证书..."

    if ! certbot certonly \
        --webroot \
        -w "$NGINX_ROOT" \
        -d "$domain" \
        --non-interactive \
        --agree-tos \
        --email "$email"; then

        err "证书申请失败，请检查 DNS、80 端口和安全组。"
        return 1
    fi

    token="$(openssl rand -hex 24)"

    printf '%s\n' "$token" > "${TOKEN_FILE}.tmp"
    mv "${TOKEN_FILE}.tmp" "$TOKEN_FILE"

    printf '%s\n' "$domain" > "${SETTINGS_FILE}.tmp"
    mv "${SETTINGS_FILE}.tmp" "$SETTINGS_FILE"

    cat > "$NGINX_CONF" <<NGINX
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

    ssl_certificate /etc/letsencrypt/live/${domain}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${domain}/privkey.pem;

    root ${NGINX_ROOT};

    location /sub/ {
        default_type text/plain;
        try_files \$uri =404;
    }

    location / {
        return 404;
    }
}
NGINX

    ln -s "$NGINX_CONF" "$NGINX_LINK"

    if ! nginx -t; then
        rm -f "$NGINX_LINK" "$NGINX_CONF"
        err "Nginx 配置检查失败，已撤销本次新增的配置。"
        return 1
    fi

    if ! systemctl reload nginx; then
        err "Nginx 重载失败，请检查服务状态。"
        return 1
    fi

    mkdir -p /etc/letsencrypt/renewal-hooks/deploy

    cat > "/etc/letsencrypt/renewal-hooks/deploy/${APP_NAME}.sh" <<'HOOK'
#!/usr/bin/env bash
nginx -t && systemctl reload nginx
HOOK
    chmod 755 "/etc/letsencrypt/renewal-hooks/deploy/${APP_NAME}.sh"

    ok "HTTPS 订阅配置完成。"
}

# ============================================================
# 订阅写入与聚合
# ============================================================

write_subscription() {
    local raw_file="$1"
    local domain token out_file

    if [[ ! -s "$raw_file" ]]; then
        warn "没有可生成的节点链接。"
        return 1
    fi

    if [[ -s "$SETTINGS_FILE" && -s "$TOKEN_FILE" ]]; then
        domain="$(head -n 1 "$SETTINGS_FILE")"
        token="$(head -n 1 "$TOKEN_FILE")"
        out_file="${SUB_DIR}/${token}"

        mkdir -p "$SUB_DIR"
        base64 -w 0 "$raw_file" > "${out_file}.tmp"
        mv "${out_file}.tmp" "$out_file"
        chmod 644 "$out_file"

        echo
        ok "HTTPS 订阅已更新："
        printf 'https://%s/sub/%s\n' "$domain" "$token"
        return 0
    fi

    echo
    info "当前未配置 HTTPS 订阅，节点链接如下："
    cat "$raw_file"
}

aggregate_subscription() {
    local tmp="${DATA_DIR}/subscription.raw"

    touch "$NODES_FILE"

    grep -E '^(vless|vmess|trojan|ss|hysteria2|tuic)://' \
        "$NODES_FILE" 2>/dev/null |
        awk '!seen[$0]++' > "$tmp" || true

    if [[ ! -s "$tmp" ]]; then
        warn "当前没有已登记的节点链接。"
        return 0
    fi

    write_subscription "$tmp"
}

# ============================================================
# 一键部署 VLESS-REALITY
# ============================================================

deploy_reality() {
    local mode port ip uuid keys private_key public_key sid remark link
    local raw_file="${DATA_DIR}/subscription.raw"

    echo
    echo "请选择订阅模式："
    echo "1. 域名 + HTTPS 订阅"
    echo "2. 不使用域名（默认）"

    read -r -p "请选择 [默认 2]：" mode
    mode="${mode:-2}"

    if [[ "$mode" != "1" && "$mode" != "2" ]]; then
        err "无效选项。"
        return 1
    fi

    install_packages
    install_xray

    if [[ "$mode" == "1" ]]; then
        if ! configure_https_subscription; then
            return 1
        fi
    fi

    ip="$(get_public_ip)" || return 1
    port="$(random_port)" || return 1
    uuid="$(cat /proc/sys/kernel/random/uuid)"
    sid="$(openssl rand -hex 4)"
    remark="XiaZheTeng-REALITY-${port}"

    keys="$(reality_keys)" || return 1
    private_key="$(printf '%s\n' "$keys" | sed -n '1p')"
    public_key="$(printf '%s\n' "$keys" | sed -n '2p')"

    if [[ -z "$private_key" || -z "$public_key" ]]; then
        err "密钥解析结果为空，已停止部署。"
        return 1
    fi

    if [[ -f "$XRAY_CONFIG" ]]; then
        cp -a "$XRAY_CONFIG" "${XRAY_CONFIG}.bak.$(date +%Y%m%d%H%M%S)"
    fi

    cat > "${XRAY_CONFIG}.tmp" <<JSON
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "tag": "xiazheteng-reality",
      "listen": "0.0.0.0",
      "port": ${port},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${uuid}",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "raw",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "www.microsoft.com:443",
          "xver": 0,
          "serverNames": [
            "www.microsoft.com"
          ],
          "privateKey": "${private_key}",
          "shortIds": [
            "${sid}"
          ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ]
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    },
    {
      "protocol": "blackhole",
      "tag": "block"
    }
  ]
}
JSON

    if ! "$XRAY" run -test -config "${XRAY_CONFIG}.tmp"; then
        rm -f "${XRAY_CONFIG}.tmp"
        err "Xray 配置测试失败，服务未启动。"
        return 1
    fi

    mv "${XRAY_CONFIG}.tmp" "$XRAY_CONFIG"
    chmod 600 "$XRAY_CONFIG"

    cat > "${SERVICE_FILE}.tmp" <<SERVICE
[Unit]
Description=XiaZheTeng Node Manager Xray Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=${XRAY} run -config ${XRAY_CONFIG}
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
SERVICE

    mv "${SERVICE_FILE}.tmp" "$SERVICE_FILE"

    systemctl daemon-reload

    if ! systemctl enable --now "$SERVICE_NAME"; then
        err "节点服务启动失败。"
        journalctl -u "$SERVICE_NAME" -n 50 --no-pager || true
        return 1
    fi

    if ! systemctl is-active --quiet "$SERVICE_NAME"; then
        err "节点服务未处于运行状态。"
        journalctl -u "$SERVICE_NAME" -n 50 --no-pager || true
        return 1
    fi

    sleep 1

    if ! ss -H -lnt 2>/dev/null |
        awk '{print $4}' |
        grep -Eq "[:.]${port}$"; then
        warn "暂未检测到端口监听，请检查服务日志。"
    fi

    link="$(make_reality_link "$ip" "$port" "$uuid" "$public_key" "$sid" "$remark")"

    touch "$NODES_FILE"
    if ! grep -Fxq "$link" "$NODES_FILE"; then
        printf '%s\n' "$link" >> "$NODES_FILE"
    fi

    aggregate_subscription

    echo
    ok "VLESS-REALITY 部署完成。"
    printf '服务器 IPv4：%s\n' "$ip"
    printf '监听端口：%s\n' "$port"
    printf '客户端 UUID：%s\n' "$uuid"
    printf 'REALITY 公钥：%s\n' "$public_key"
    printf 'Short ID：%s\n' "$sid"
    echo
    warn "请在云服务商安全组中放行 TCP ${port}。"
    warn "脚本不会自动修改云服务商安全组。"
}

# ============================================================
# 服务管理
# ============================================================

service_status() {
    echo
    systemctl status "$SERVICE_NAME" --no-pager || true
}

restart_service() {
    if [[ ! -f "$SERVICE_FILE" ]]; then
        warn "本项目节点服务尚未安装。"
        return 0
    fi

    systemctl restart "$SERVICE_NAME"
    systemctl status "$SERVICE_NAME" --no-pager || true
}

uninstall_manager() {
    local answer

    echo
    warn "只卸载本管理器创建的节点服务和配置。"
    warn "不会清空防火墙，也不会自动卸载共享软件。"

    read -r -p "确认卸载？[y/N]：" answer

    case "${answer,,}" in
        y|yes)
            systemctl disable --now "$SERVICE_NAME" 2>/dev/null || true
            rm -f "$SERVICE_FILE"
            systemctl daemon-reload

            if [[ -L "$NGINX_LINK" ]] &&
                [[ "$(readlink -f "$NGINX_LINK")" == "$NGINX_CONF" ]]; then
                rm -f "$NGINX_LINK" "$NGINX_CONF"
                nginx -t && systemctl reload nginx || true
            fi

            rm -f "/etc/letsencrypt/renewal-hooks/deploy/${APP_NAME}.sh"
            rm -rf "$BASE_DIR"

            warn "本管理器服务和配置已删除。"
            warn "共享软件包和证书未自动删除。"
            ;;
        *)
            info "已取消。"
            ;;
    esac
}

# ============================================================
# 更多功能
# ============================================================

more_features() {
    local choice

    while true; do
        echo
        echo "========== 更多功能 =========="
        echo "1. 查看节点服务状态"
        echo "2. 重启节点服务"
        echo "3. 查看配置路径"
        echo "4. 查看订阅聚合结果"
        echo "0. 返回主菜单"

        read -r -p "请选择：" choice

        case "$choice" in
            1)
                service_status
                pause
                ;;
            2)
                restart_service
                pause
                ;;
            3)
                echo "Xray 配置：$XRAY_CONFIG"
                echo "节点列表：$NODES_FILE"
                echo "管理器：$MANAGER_PATH"
                pause
                ;;
            4)
                aggregate_subscription
                pause
                ;;
            0)
                return
                ;;
            *)
                warn "无效选项。"
                ;;
        esac
    done
}

# ============================================================
# 主菜单：所有功能统一在本脚本中
# ============================================================

show_menu() {
    local choice subchoice

    while true; do
        clear 2>/dev/null || true

        echo "=============================================="
        echo "       ${APP_TITLE}"
        echo "=============================================="
        echo "网络模式：IPv4-only"
        echo "----------------------------------------------"
        echo "1. 一键部署"
        echo "   ├─ VLESS-REALITY + HTTPS 订阅"
        echo "   └─ VLESS-REALITY 无域名部署"
        echo "2. 其他部署方式"
        echo "3. 节点管理与订阅聚合"
        echo "4. 系统与服务设置"
        echo "5. 更多功能"
        echo "6. 卸载本项目节点服务"
        echo "0. 退出"
        echo "----------------------------------------------"
        echo "快捷键：x / X 返回菜单，q / Q 退出"
        echo

        read -r -p "请选择：" choice || exit 0

        case "${choice,,}" in
            1)
                deploy_reality
                pause
                ;;
            2)
                echo
                echo "========== 其他部署方式 =========="
                echo "当前此菜单作为统一扩展入口。"
                echo "勇哥脚本中的具体部署功能必须逐项整合后才能在此启用。"
                echo "本菜单不会另行启动或下载第二个管理脚本。"
                pause
                ;;
            3)
                aggregate_subscription
                pause
                ;;
            4)
                echo
                echo "========== 系统与服务设置 =========="
                echo "1. 查看本项目服务状态"
                echo "2. 重启本项目服务"
                echo "0. 返回"

                read -r -p "请选择：" subchoice

                case "$subchoice" in
                    1)
                        service_status
                        pause
                        ;;
                    2)
                        restart_service
                        pause
                        ;;
                    *)
                        ;;
                esac
                ;;
            5)
                more_features
                ;;
            6)
                uninstall_manager
                pause
                ;;
            0|q)
                exit 0
                ;;
            x)
                continue
                ;;
            *)
                warn "无效选项。"
                pause
                ;;
        esac
    done
}

main() {
    need_root
    install_shortcut
    show_menu
}

main "$@"
