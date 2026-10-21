#!/usr/bin/env bash
# ============================================================
# 瞎折腾吧 | VPS 多协议节点管理器
# GitHub:   https://github.com/xiazheteng8/xiazheteng-node-manager
# YouTube:  https://www.youtube.com/@xiazheteng8
# Telegram: https://t.me/xiazheteng8
#
# 设计目标：
#   1. 一键部署入口
#   2. 无域名 / 域名已解析两种模式
#   3. 保留现有独立 Xray 服务与订阅服务
#   4. 不清空防火墙，不覆盖系统默认 Xray 配置
#   5. SSH 快捷命令 X
#
# 注意：本版本提供管理框架和安全检查入口，
# 不代表所有第三方协议均已实现部署。
# ============================================================

set -Eeuo pipefail
umask 077

readonly APP_NAME="xiazheteng-node-manager"
readonly APP_VERSION="0.1.0"
readonly GITHUB_URL="https://github.com/xiazheteng8/xiazheteng-node-manager"
readonly YOUTUBE_URL="https://www.youtube.com/@xiazheteng8"
readonly TELEGRAM_URL="https://t.me/xiazheteng8"

# 已有无证书节点：严禁随意覆盖或删除
readonly XRAY_BIN="/usr/local/bin/xray"
readonly XRAY_CONFIG="/usr/local/etc/xray/node-manager-nocert.json"
readonly XRAY_SERVICE="xray-node-manager-nocert.service"
readonly SUB_SERVICE="node-manager-nocert-subscription.service"
readonly SUB_FILE="/var/lib/node-manager-nocert/subscription.txt"

readonly DATA_DIR="/var/lib/xiazheteng-node-manager"
readonly BACKUP_DIR="/root/xiazheteng-node-manager-backups"
readonly LOG_FILE="/var/log/xiazheteng-node-manager.log"
readonly COMMAND_PATH="/usr/local/bin/X"

mkdir -p "$DATA_DIR" "$BACKUP_DIR"
touch "$LOG_FILE"
chmod 600 "$LOG_FILE"

log() {
    printf '[%s] %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG_FILE"
}

info() {
    printf '\033[36m[信息]\033[0m %s\n' "$*"
}

success() {
    printf '\033[32m[成功]\033[0m %s\n' "$*"
}

warn() {
    printf '\033[33m[警告]\033[0m %s\n' "$*" >&2
}

error() {
    printf '\033[31m[错误]\033[0m %s\n' "$*" >&2
}

pause() {
    printf '\n按 Enter 返回菜单...'
    read -r _ || true
}

require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        error "请使用 root 运行此脚本。"
        exit 1
    fi
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# 只读取公网 IP，不修改网络配置。
# 多个检测源失败时返回空字符串，不使用内网地址冒充公网地址。
detect_public_ipv4() {
    local ip=""
    local url

    for url in \
        "https://api.ipify.org" \
        "https://ipv4.icanhazip.com" \
        "https://checkip.amazonaws.com"
    do
        ip="$(curl -4 -fsS --connect-timeout 3 --max-time 6 "$url" 2>/dev/null \
            | tr -d '[:space:]' || true)"

        if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
            if python3 - "$ip" <<'PY' >/dev/null 2>&1
import ipaddress, sys
ip = ipaddress.ip_address(sys.argv[1])
assert ip.version == 4 and ip.is_global
PY
            then
                printf '%s\n' "$ip"
                return 0
            fi
        fi
    done

    return 1
}

detect_public_ipv6() {
    local ip=""

    ip="$(curl -6 -fsS --connect-timeout 3 --max-time 6 \
        https://api64.ipify.org 2>/dev/null | tr -d '[:space:]' || true)"

    if [[ "$ip" == *:* ]]; then
        printf '%s\n' "$ip"
        return 0
    fi

    return 1
}

service_exists() {
    systemctl cat "$1" >/dev/null 2>&1
}

service_state() {
    local service="$1"

    if ! service_exists "$service"; then
        printf '未安装'
        return
    fi

    if systemctl is-active --quiet "$service"; then
        printf '运行中'
    else
        printf '未运行'
    fi
}

# 只检查现有服务和配置，不执行重置或覆盖操作。
show_existing_services() {
    printf '\n========== 现有服务检查 ==========\n'

    printf 'Xray 程序：'
    if [[ -x "$XRAY_BIN" ]]; then
        "$XRAY_BIN" version 2>/dev/null | head -n 1 || true
    else
        printf '未找到\n'
    fi

    printf '无证书配置：%s\n' \
        "$([[ -f "$XRAY_CONFIG" ]] && echo 存在 || echo 不存在)"

    printf '无证书服务：%s\n' "$(service_state "$XRAY_SERVICE")"
    printf '订阅服务：%s\n' "$(service_state "$SUB_SERVICE")"

    printf '订阅文件：%s\n' \
        "$([[ -f "$SUB_FILE" ]] && echo 存在 || echo 不存在)"

    # 明确说明：不操作系统默认 Xray 服务
    printf '系统默认 xray.service：不修改\n'
    printf '系统默认 Xray 配置：不修改\n'
}

# 使用只读的 Xray test 检查已有配置。
check_existing_xray() {
    printf '\n========== 无证书 Xray 配置检查 ==========\n'

    if [[ ! -x "$XRAY_BIN" ]]; then
        warn "未找到 $XRAY_BIN"
        return 1
    fi

    if [[ ! -f "$XRAY_CONFIG" ]]; then
        warn "未找到 $XRAY_CONFIG；不会创建或覆盖现有配置。"
        return 1
    fi

    if "$XRAY_BIN" run -test -config "$XRAY_CONFIG"; then
        success "现有无证书 Xray 配置校验通过。"
    else
        error "现有配置校验失败；没有自动修改配置。"
        return 1
    fi
}

show_subscription() {
    printf '\n========== 现有订阅信息 ==========\n'

    if [[ ! -f "$SUB_FILE" ]]; then
        warn "订阅文件不存在：$SUB_FILE"
        return
    fi

    printf '订阅文件：%s\n' "$SUB_FILE"
    printf '订阅服务：%s\n' "$(service_state "$SUB_SERVICE")"

    if command_exists grep; then
        if grep -Eq '^https?://' "$SUB_FILE"; then
            printf '\n文件中的 URL：\n'
            grep -E '^https?://' "$SUB_FILE" || true
        else
            printf '\n订阅文件内容：\n'
            cat "$SUB_FILE"
        fi
    fi
}

backup_configs() {
    local dest
    dest="$BACKUP_DIR/backup-$(date '+%Y%m%d-%H%M%S')"

    mkdir -p "$dest"

    local found=0
    local path

    for path in "$XRAY_CONFIG" "$SUB_FILE"; do
        if [[ -f "$path" ]]; then
            mkdir -p "$dest$(dirname "$path")"
            cp -a "$path" "$dest$path"
            found=1
        fi
    done

    if [[ -d /etc/systemd/system ]]; then
        mkdir -p "$dest/etc/systemd/system"

        if [[ -f "/etc/systemd/system/$XRAY_SERVICE" ]]; then
            cp -a "/etc/systemd/system/$XRAY_SERVICE" \
                "$dest/etc/systemd/system/"
            found=1
        fi

        if [[ -f "/etc/systemd/system/$SUB_SERVICE" ]]; then
            cp -a "/etc/systemd/system/$SUB_SERVICE" \
                "$dest/etc/systemd/system/"
            found=1
        fi
    fi

    if [[ "$found" -eq 1 ]]; then
        success "备份完成：$dest"
    else
        warn "未找到可备份的现有配置。备份目录：$dest"
    fi
}

list_backups() {
    printf '\n========== 备份列表 ==========\n'

    if [[ ! -d "$BACKUP_DIR" ]]; then
        printf '暂无备份。\n'
        return
    fi

    find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d \
        -printf '%TY-%Tm-%Td %TH:%TM  %f\n' 2>/dev/null \
        | sort -r || true
}

# 查找现有配置中可能出现的域名。
# 不根据公网 IP 猜测域名，不把 IP 当作域名。
discover_configured_domains() {
    local files=(
        "$XRAY_CONFIG"
        "/etc/nginx/sites-enabled/default"
        "/etc/nginx/nginx.conf"
    )

    local file
    for file in "${files[@]}"; do
        [[ -f "$file" ]] || continue

        grep -Eho \
            'server_name[[:space:]]+[^;]+' "$file" 2>/dev/null \
            | sed -E 's/server_name[[:space:]]+//' \
            | tr ' ' '\n' \
            | grep -E '^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$' \
            | sort -u || true
    done
}

# 当前版本不自动申请证书、不擅自更改 DNS。
# 只检测现有证书信息，避免误改网站证书。
show_certificate_status() {
    printf '\n========== 证书检查 ==========\n'

    if command_exists certbot; then
        certbot certificates 2>/dev/null || true
    else
        info "未检测到 Certbot。"
    fi

    if [[ -d /etc/letsencrypt/live ]]; then
        printf '\n现有 Let's Encrypt 证书目录：\n'
        find /etc/letsencrypt/live -mindepth 1 -maxdepth 1 \
            -type d -printf '%f\n' 2>/dev/null || true
    else
        info "未检测到 Let's Encrypt live 目录。"
    fi
}

deployment_no_domain() {
    printf '\n========== 一键部署：没有域名 ==========\n'
    warn "当前脚本版本不会自动安装或覆盖节点服务。"

    local ip=""
    if ip="$(detect_public_ipv4)"; then
        printf '检测到的 VPS 公网 IPv4：%s\n' "$ip"
    else
        warn "无法自动检测公网 IPv4。请检查 VPS 网络连接。"
    fi

    if ip="$(detect_public_ipv6)"; then
        printf '检测到的 VPS 公网 IPv6：%s\n' "$ip"
    fi

    printf '\n检查现有无证书节点：\n'
    check_existing_xray || true

    printf '\n说明：\n'
    printf '  - 现有 REALITY 和 Shadowsocks 配置不会被覆盖。\n'
    printf '  - 此版本尚未实现完整的多协议自动部署。\n'
    printf '  - 不会输出虚假的订阅地址。\n'
}

deployment_domain() {
    printf '\n========== 一键部署：域名已解析到 VPS 的 IP ==========\n'

    local ip=""
    if ! ip="$(detect_public_ipv4)"; then
        error "无法检测公网 IPv4，不能验证域名解析目标。"
        return 1
    fi

    printf '检测到的 VPS 公网 IPv4：%s\n' "$ip"

    printf '\n从现有配置中发现的域名：\n'
    local domains
    domains="$(discover_configured_domains || true)"

    if [[ -n "$domains" ]]; then
        printf '%s\n' "$domains"
    else
        warn "未从当前检查的配置中发现可复用域名。"
        warn "仅凭 VPS 公网 IP 无法推断你的域名。"
    fi

    show_certificate_status

    printf '\n检查现有无证书节点：\n'
    check_existing_xray || true

    printf '\n说明：\n'
    printf '  - 不会自动覆盖网站证书或 Nginx 配置。\n'
    printf '  - 不会将未验证的域名写入订阅。\n'
    printf '  - 此版本尚未实现完整的多协议自动部署。\n'
}

install_shortcut() {
    local target

    target="$(readlink -f "$0")"

    if [[ ! -f "$target" ]]; then
        error "无法确定脚本真实路径，不能安装快捷命令。"
        return 1
    fi

    cat > "$COMMAND_PATH" <<EOF
#!/usr/bin/env bash
exec bash "$target" "\$@"
EOF

    chmod 755 "$COMMAND_PATH"
    success "已安装 SSH 快捷命令：X"
    printf '以后可在 SSH 中输入大写 X 启动管理器。\n'
}

show_diagnostics() {
    printf '\n========== 服务与诊断 ==========\n'
    show_existing_services

    printf '\n========== 端口监听 ==========\n'
    if command_exists ss; then
        ss -lntup 2>/dev/null || true
    else
        warn "未安装 ss 命令。"
    fi

    printf '\n========== 最近日志 ==========\n'
    tail -n 40 "$LOG_FILE" 2>/dev/null || true

    printf '\n========== 域名与证书 ==========\n'
    discover_configured_domains || true
    show_certificate_status
}

update_manager() {
    warn "更新功能需要先完成仓库版本和下载校验逻辑。"
    warn "当前不会自动覆盖本地脚本。"
}

main_menu() {
    while true; do
        clear 2>/dev/null || true

        local ip_display="无法检测"
        ip_display="$(detect_public_ipv4 2>/dev/null || printf '无法检测')"

        cat <<EOF
====================================================
       瞎折腾吧 | VPS 多协议节点管理器
====================================================
版本：$APP_VERSION
VPS 公网 IPv4：$ip_display

  1. 一键部署节点
  2. 节点管理与配置检查
  3. 订阅管理
  4. 服务状态与故障诊断
  5. 备份与恢复
  6. 安装 SSH 快捷命令 X
  7. 更新管理器
  0. 退出

====================================================
EOF

        printf '请选择：'
        local choice
        read -r choice || return 0

        case "$choice" in
            1)
                deployment_menu
                ;;
            2)
                show_existing_services
                check_existing_xray || true
                pause
                ;;
            3)
                show_subscription
                pause
                ;;
            4)
                show_diagnostics
                pause
                ;;
            5)
                backup_menu
                ;;
            6)
                install_shortcut
                pause
                ;;
            7)
                update_manager
                pause
                ;;
            0)
                exit 0
                ;;
            *)
                warn "无效选项。"
                sleep 1
                ;;
        esac
    done
}

deployment_menu() {
    while true; do
        clear 2>/dev/null || true

        local ip_display="无法检测"
        ip_display="$(detect_public_ipv4 2>/dev/null || printf '无法检测')"

        cat <<EOF
============== 一键部署节点 ==============

  1. 没有域名
  2. 域名已解析到 $ip_display
  0. 返回主菜单

==========================================
EOF

        printf '请选择：'
        local choice
        read -r choice || return 0

        case "$choice" in
            1)
                deployment_no_domain
                pause
                ;;
            2)
                deployment_domain || true
                pause
                ;;
            0)
                return 0
                ;;
            *)
                warn "无效选项。"
                sleep 1
                ;;
        esac
    done
}

backup_menu() {
    while true; do
        clear 2>/dev/null || true

        cat <<'EOF'
============== 备份与恢复 ==============

  1. 备份现有节点配置
  2. 查看备份列表
  0. 返回主菜单

========================================
EOF

        printf '请选择：'
        local choice
        read -r choice || return 0

        case "$choice" in
            1)
                backup_configs
                pause
                ;;
            2)
                list_backups
                pause
                ;;
            0)
                return 0
                ;;
            *)
                warn "无效选项。"
                sleep 1
                ;;
        esac
    done
}

main() {
    require_root

    log "启动 $APP_NAME v$APP_VERSION"

    main_menu
}

main "$@"
