
#!/usr/bin/env bash
# ============================================================
# 瞎折腾吧 | 3x-ui VPS 自动部署管理器
# 支持：Debian / Ubuntu
# 地址：运行时输入域名或 IP，不预设个人域名
# Cloudflare：默认关闭；可选配置 HTTP 服务 Tunnel
#
# 安全原则：
#   1. 修改前备份
#   2. 不自动删除已有网站或证书
#   3. API Token 不写入脚本、不回显
#   4. 不将未经验证的节点标记为可用
# ============================================================

set -Eeuo pipefail
umask 077

APP="xiazheteng-3xui-manager"
STATE="/etc/${APP}"
BACKUP="/var/backups/${APP}"
LOG="/var/log/${APP}.log"
INSTALL_URL="https://raw.githubusercontent.com/MHSanaei/3x-ui/master/install.sh"

SERVER_ADDRESS=""
SERVER_MODE=""
SUB_SECRET=""
CF_ENABLED="false"

log()  { printf '[成功] %s\n' "$*"; }
info() { printf '[信息] %s\n' "$*"; }
warn() { printf '[警告] %s\n' "$*" >&2; }
die()  { printf '[错误] %s\n' "$*" >&2; exit 1; }

on_error() {
    local code=$?
    printf '[错误] 第 %s 行执行失败，退出码 %s\n' \
        "${BASH_LINENO[0]:-unknown}" "$code" >&2
    printf '[信息] 日志：%s\n' "$LOG" >&2
    exit "$code"
}
trap on_error ERR

require_root() {
    [[ $EUID -eq 0 ]] || die "请以 root 身份运行：sudo bash $0"
}

init_dirs() {
    install -d -m 700 "$STATE" "$BACKUP"
    touch "$LOG"
    chmod 600 "$LOG"
}

check_os() {
    [[ -r /etc/os-release ]] || die "无法识别操作系统"
    # shellcheck disable=SC1091
    . /etc/os-release

    case "${ID:-}" in
        debian|ubuntu) ;;
        *) die "不支持自动修改此系统：${PRETTY_NAME:-unknown}" ;;
    esac

    case "$(uname -m)" in
        x86_64|aarch64|arm64) ;;
        *) die "未验证的 CPU 架构：$(uname -m)" ;;
    esac

    info "系统：${PRETTY_NAME:-unknown}"
    info "架构：$(uname -m)"
}

install_dependencies() {
    export DEBIAN_FRONTEND=noninteractive

    apt-get update
    apt-get install -y --no-install-recommends \
        ca-certificates curl jq openssl \
        dnsutils iproute2 lsof tar gzip \
        coreutils python3 sqlite3

    log "依赖安装完成"
}

update_system() {
    install_dependencies
    apt-get upgrade -y

    if [[ -f /var/run/reboot-required ]]; then
        warn "系统更新后需要重启，请自行安排维护窗口"
    fi

    log "系统更新完成"
}

# ------------------------------------------------------------
# 地址输入：域名、IPv4、IPv6
# ------------------------------------------------------------
collect_server_address() {
    local value valid label
    local labels=()

    while true; do
        read -r -p "请输入服务器域名或公网 IP（不带端口）：" value
        value="${value#https://}"
        value="${value#http://}"
        value="${value%/}"

        if [[ -z "$value" ||
              "$value" == *"/"* ||
              "$value" == *"@"* ||
              "$value" == *" "* ||
              "$value" == *"?"* ||
              "$value" == *"#"* ]]; then
            warn "只输入域名或 IP，不要包含 URL 路径、端口或凭据"
            continue
        fi

        if [[ "$value" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            if ! python3 -c \
                'import ipaddress,sys; ipaddress.IPv4Address(sys.argv[1])' \
                "$value" 2>/dev/null; then
                warn "IPv4 地址无效"
                continue
            fi
            SERVER_MODE="ipv4"

        elif [[ "$value" == *:* ]]; then
            if ! python3 -c \
                'import ipaddress,sys; ipaddress.IPv6Address(sys.argv[1])' \
                "$value" 2>/dev/null; then
                warn "IPv6 地址无效"
                continue
            fi
            SERVER_MODE="ipv6"

        else
            if (( ${#value} > 253 )); then
                warn "域名长度超出限制"
                continue
            fi

            IFS='.' read -r -a labels <<< "$value"
            valid=true

            for label in "${labels[@]}"; do
                if (( ${#label} < 1 || ${#label} > 63 )) ||
                   [[ ! "$label" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$ ]]; then
                    valid=false
                    break
                fi
            done

            if [[ "$valid" != true || "$value" != *.* ]]; then
                warn "域名格式无效，请输入完整域名"
                continue
            fi

            SERVER_MODE="domain"
        fi

        SERVER_ADDRESS="$value"
        break
    done

    printf '%s\n' "$SERVER_ADDRESS" > "$STATE/server-address"
    printf '%s\n' "$SERVER_MODE" > "$STATE/server-mode"
    chmod 600 "$STATE/server-address" "$STATE/server-mode"

    log "服务器地址已保存：$SERVER_ADDRESS（$SERVER_MODE）"
}

load_server_address() {
    if [[ -s "$STATE/server-address" ]]; then
        SERVER_ADDRESS="$(<"$STATE/server-address")"
        SERVER_MODE="$(<"$STATE/server-mode")"
    else
        collect_server_address
    fi
}

# ------------------------------------------------------------
# 备份：只复制已存在的配置，不删除原文件
# ------------------------------------------------------------
create_backup() {
    local stamp dest
    stamp="$(date +%Y%m%d-%H%M%S)"
    dest="$BACKUP/$stamp"

    install -d -m 700 "$dest"

    local path
    for path in \
        /etc/x-ui \
        /usr/local/x-ui \
        /etc/nginx \
        /etc/letsencrypt \
        /etc/ssl
    do
        if [[ -e "$path" ]]; then
            cp -a "$path" "$dest/"
        fi
    done

    if command -v x-ui >/dev/null 2>&1; then
        x-ui settings > "$dest/x-ui-settings.txt" 2>&1 || true
    fi

    chmod -R go-rwx "$dest"
    printf '%s\n' "$dest" > "$STATE/last-backup"

    log "备份完成：$dest"
}

# ------------------------------------------------------------
# 端口与服务诊断
# ------------------------------------------------------------
diagnose_ports() {
    echo
    echo "===== 常用端口监听 ====="
    ss -lntup || true

    echo
    echo "===== 80 / 443 / 2053 / 8443 ====="
    for port in 80 443 2053 8443; do
        if command -v lsof >/dev/null 2>&1; then
            lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null || true
        fi
    done

    echo
    echo "===== 相关服务 ====="
    for service in x-ui nginx apache2 cloudflared; do
        if systemctl list-unit-files "${service}.service" \
            >/dev/null 2>&1; then
            systemctl --no-pager --full status "$service" 2>&1 |
                head -n 15 || true
        fi
    done
}

# ------------------------------------------------------------
# 官方 3x-ui 安装
# 使用官方仓库脚本，不覆盖已有 Nginx/证书。
# ------------------------------------------------------------
install_3xui() {
    echo
    warn "安装器来自官方 3x-ui GitHub 仓库"
    warn "请先确认 VPS 上没有不允许中断的生产业务"
    read -r -p "是否备份并继续安装？输入 YES 确认：" confirm
    [[ "$confirm" == "YES" ]] || {
        info "已取消"
        return
    }

    create_backup

    local tmp
    tmp="$(mktemp)"
    chmod 600 "$tmp"

    info "下载官方安装脚本"
    if ! curl -fsSL --retry 3 --connect-timeout 15 \
        "$INSTALL_URL" -o "$tmp"; then
        rm -f "$tmp"
        die "下载官方安装脚本失败"
    fi

    [[ -s "$tmp" ]] || {
        rm -f "$tmp"
        die "安装脚本为空"
    }

    if ! head -n 1 "$tmp" | grep -qE '^#!.*(bash|sh)'; then
        rm -f "$tmp"
        die "下载内容不像 Shell 脚本，拒绝执行"
    fi

    bash -n "$tmp" || {
        rm -f "$tmp"
        die "官方安装脚本语法检查失败"
    }

    echo
    info "开始运行官方安装程序；按其交互提示完成安装"
    bash "$tmp"
    rm -f "$tmp"

    if systemctl list-unit-files x-ui.service >/dev/null 2>&1; then
        systemctl enable --now x-ui || true
    fi

    if command -v x-ui >/dev/null 2>&1; then
        x-ui settings || true
    fi

    log "官方安装程序执行完毕；请确认面板服务和登录信息"
}

# ------------------------------------------------------------
# 订阅密钥
# 说明：此处生成的是本管理器的随机密钥。
# 不会擅自修改 3x-ui 数据库或声称订阅已生效。
# ------------------------------------------------------------
generate_subscription_secret() {
    local secret_file="$STATE/subscription-secret"

    if [[ ! -s "$secret_file" ]]; then
        openssl rand -hex 32 > "$secret_file"
        chmod 600 "$secret_file"
        log "已生成随机订阅密钥"
    else
        info "检测到已有订阅密钥，保持不变"
    fi

    SUB_SECRET="$(<"$secret_file")"

    load_server_address

    echo
    echo "===== 订阅信息 ====="
    echo "服务器地址：$SERVER_ADDRESS"
    echo "订阅密钥：$SUB_SECRET"

    if [[ "$SERVER_MODE" == "domain" ]]; then
        echo "候选 HTTPS 订阅地址：https://${SERVER_ADDRESS}/sub/${SUB_SECRET}"
    else
        echo "候选 HTTP 订阅地址：http://${SERVER_ADDRESS}/sub/${SUB_SECRET}"
        warn "IP 直连下的 HTTPS 证书需单独验证"
    fi

    warn "以上是候选地址，不代表 3x-ui 已创建对应订阅端点。"
    warn "请在面板中核实订阅设置，并通过 curl 实际验证返回内容。"
}

# ------------------------------------------------------------
# DNS 检查
# ------------------------------------------------------------
check_dns() {
    load_server_address

    if [[ "$SERVER_MODE" != "domain" ]]; then
        info "当前输入为 IP，无需 DNS 查询"
        return
    fi

    echo "===== DNS A 记录 ====="
    dig +short A "$SERVER_ADDRESS" || true

    echo
    echo "===== DNS AAAA 记录 ====="
    dig +short AAAA "$SERVER_ADDRESS" || true

    echo
    info "请确认 DNS 指向当前 VPS 后再申请证书"
}

# ------------------------------------------------------------
# HTTPS 端点检查
# ------------------------------------------------------------
check_subscription_endpoint() {
    load_server_address
    generate_subscription_secret

    local url
    if [[ "$SERVER_MODE" == "domain" ]]; then
        url="https://${SERVER_ADDRESS}/sub/${SUB_SECRET}"
    else
        url="http://${SERVER_ADDRESS}/sub/${SUB_SECRET}"
    fi

    echo
    info "正在测试候选订阅地址：$url"

    local tmp code
    tmp="$(mktemp)"
    chmod 600 "$tmp"

    code="$(curl -sS -L --connect-timeout 8 --max-time 20 \
        -o "$tmp" -w '%{http_code}' "$url" 2>/dev/null || true)"

    echo "HTTP 状态码：${code:-请求失败}"
    echo "响应内容类型与节点格式需要另行核验。"

    if [[ "$code" == "200" ]]; then
        if jq -e . "$tmp" >/dev/null 2>&1; then
            info "响应内容可解析为 JSON"
        elif grep -qE '^[A-Za-z0-9+/=]+$' "$tmp"; then
            info "响应看起来可能是 Base64 编码内容"
        else
            info "已收到响应；请检查是否为有效订阅内容"
        fi
    else
        warn "订阅端点未通过 HTTP 200 检查"
    fi

    rm -f "$tmp"
}

# ------------------------------------------------------------
# Cloudflare Tunnel（仅发布 HTTP 服务）
# 不会把代理协议端口自动转换成 HTTP Tunnel。
# 需要有权限的 API Token、Account ID、Zone ID。
# ------------------------------------------------------------
cloudflare_tunnel() {
    echo
    echo "Cloudflare Tunnel 仅适用于发布 HTTP/HTTPS Web 服务。"
    echo "它不能直接代替所有 Xray TCP/UDP 入站。"
    echo
    read -r -p "是否继续配置？输入 YES 确认：" confirm
    [[ "$confirm" == "YES" ]] || return

    local account zone hostname service_port token tunnel_name
    local tunnel_secret tunnel_id tunnel_token api dns_result

    read -r -p "Cloudflare Account ID：" account
    read -r -p "Cloudflare Zone ID：" zone
    read -r -p "要发布的完整子域名：" hostname
    read -r -p "本机 HTTP 服务端口（例如面板实际 HTTP 端口）：" service_port
    read -r -p "Tunnel 名称：" tunnel_name

    [[ "$account" =~ ^[a-fA-F0-9]{32}$ ]] || die "Account ID 格式不正确"
    [[ "$zone" =~ ^[a-fA-F0-9]{32}$ ]] || die "Zone ID 格式不正确"
    [[ "$hostname" =~ ^[a-zA-Z0-9.-]+$ ]] || die "域名格式不正确"
    [[ "$service_port" =~ ^[0-9]+$ ]] || die "端口无效"
    (( service_port >= 1 && service_port <= 65535 )) ||
        die "端口范围无效"

    read -r -s -p "Cloudflare API Token（输入不会回显）：" token
    echo
    [[ -n "$token" ]] || die "Token 不能为空"

    api="https://api.cloudflare.com/client/v4"

    local token_response
    token_response="$(
        curl -fsS --connect-timeout 10 \
            -H "Authorization: Bearer ${token}" \
            "$api/user/tokens/verify"
    )" || die "Cloudflare Token 验证请求失败"

    if [[ "$(jq -r '.success' <<<"$token_response")" != "true" ]]; then
        unset token
        die "Cloudflare Token 验证失败"
    fi

    info "Token 有效"

    tunnel_secret="$(openssl rand -base64 32 | tr -d '\n')"
    local tunnel_payload
    tunnel_payload="$(
        jq -n \
            --arg name "$tunnel_name" \
            --arg secret "$tunnel_secret" \
            '{name:$name,tunnel_secret:$secret}'
    )"

    local create_response
    create_response="$(
        curl -fsS --connect-timeout 10 \
            -X POST "$api/accounts/$account/cfd_tunnel" \
            -H "Authorization: Bearer ${token}" \
            -H "Content-Type: application/json" \
            --data "$tunnel_payload"
    )" || {
        unset token tunnel_secret
        die "创建 Tunnel 失败，请检查 Token 的 Cloudflare Tunnel 权限"
    }

    if [[ "$(jq -r '.success' <<<"$create_response")" != "true" ]]; then
        unset token tunnel_secret
        printf '%s\n' "$create_response" |
            jq -r '.errors[]?.message' >&2 || true
        die "Cloudflare API 拒绝创建 Tunnel"
    fi

    tunnel_id="$(jq -r '.result.id // empty' <<<"$create_response")"
    [[ -n "$tunnel_id" ]] || die "未能获取 Tunnel ID"

    local tunnel_token_response
    tunnel_token_response="$(
        curl -fsS --connect-timeout 10 \
            "$api/accounts/$account/cfd_tunnel/$tunnel_id/token" \
            -H "Authorization: Bearer ${token}"
    )" || die "获取 Tunnel Token 失败"

    tunnel_token="$(jq -r '.result // empty' <<<"$tunnel_token_response")"
    [[ -n "$tunnel_token" ]] || die "Tunnel Token 为空"

    local dns_payload
    dns_payload="$(
        jq -n \
            --arg name "$hostname" \
            --arg content "${tunnel_id}.cfargotunnel.com" \
            '{type:"CNAME",name:$name,content:$content,proxied:true,ttl:1}'
    )"

    dns_result="$(
        curl -fsS --connect-timeout 10 \
            -X POST "$api/zones/$zone/dns_records" \
            -H "Authorization: Bearer ${token}" \
            -H "Content-Type: application/json" \
            --data "$dns_payload"
    )" || die "创建 DNS 记录失败"

    if [[ "$(jq -r '.success' <<<"$dns_result")" != "true" ]]; then
        printf '%s\n' "$dns_result" |
            jq -r '.errors[]?.message' >&2 || true
        die "DNS 记录创建失败；检查 Zone 权限和同名记录冲突"
    fi

    # 将隧道凭据交给 cloudflared 服务安装命令，不写入脚本文件。
    if ! command -v cloudflared >/dev/null 2>&1; then
        info "安装 cloudflared"
        local arch pkg
        arch="$(uname -m)"
        case "$arch" in
            x86_64) pkg="amd64" ;;
            aarch64|arm64) pkg="arm64" ;;
            *) die "不支持的 cloudflared 架构：$arch" ;;
        esac

        local deb
        deb="$(mktemp --suffix=.deb)"
        curl -fsSL --retry 3 \
            "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${pkg}.deb" \
            -o "$deb"
        apt-get install -y "$deb"
        rm -f "$deb"
    fi

    # 使用 systemd 管理 Tunnel。安装程序会将凭据写入服务配置。
    cloudflared service install "$tunnel_token" ||
        die "cloudflared 服务安装失败，请检查现有服务和安装状态"

    systemctl enable --now cloudflared || true

    unset token tunnel_secret tunnel_token tunnel_payload
    log "Tunnel 与 DNS 已提交创建请求"
    warn "请确认 cloudflared 服务实际连接成功"
    warn "本机服务端口必须提供 HTTP 服务；Tunnel 不会自动配置 Xray 入站"
    warn "如已有 cloudflared 服务，需先检查其配置，避免覆盖"
}

# ------------------------------------------------------------
# 运行状态
# ------------------------------------------------------------
show_status() {
    echo
    echo "===== 3x-ui 服务 ====="
    if systemctl list-unit-files x-ui.service >/dev/null 2>&1; then
        systemctl --no-pager --full status x-ui || true
    else
        warn "未找到 x-ui.service"
    fi

    echo
    echo "===== x-ui 命令 ====="
    if command -v x-ui >/dev/null 2>&1; then
        x-ui settings || true
    else
        warn "未找到 x-ui 命令"
    fi

    echo
    echo "===== 当前地址 ====="
    if [[ -s "$STATE/server-address" ]]; then
        cat "$STATE/server-address"
    else
        echo "尚未设置"
    fi

    echo
    echo "===== 最近备份 ====="
    if [[ -s "$STATE/last-backup" ]]; then
        cat "$STATE/last-backup"
    else
        echo "暂无"
    fi
}

# ------------------------------------------------------------
# 菜单
# ------------------------------------------------------------
menu() {
    while true; do
        cat <<'MENU'

============================================================
 瞎折腾吧 | 3x-ui VPS 管理器
============================================================
1. 更新系统并安装依赖
2. 设置服务器域名或 IP
3. 备份配置
4. 安装 / 更新官方 3x-ui（交互式官方安装器）
5. 生成或查看订阅密钥
6. 检查 DNS
7. 检查订阅端点
8. 查看服务状态
9. 诊断端口与服务
10. Cloudflare Tunnel 高级配置（仅 HTTP 服务）
0. 退出
============================================================
MENU

        local choice
        read -r -p "请选择：" choice

        case "$choice" in
            1) update_system ;;
            2) collect_server_address ;;
            3) create_backup ;;
            4) install_3xui ;;
            5) generate_subscription_secret ;;
            6) check_dns ;;
            7) check_subscription_endpoint ;;
            8) show_status ;;
            9) diagnose_ports ;;
            10) cloudflare_tunnel ;;
            0) exit 0 ;;
            *) warn "无效选项" ;;
        esac
    done
}

main() {
    require_root
    init_dirs
    check_os

    info "本脚本不会预设你的域名"
    info "Cloudflare 功能默认关闭"

    menu
}

main "$@"
