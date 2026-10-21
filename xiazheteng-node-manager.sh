#!/usr/bin/env bash
# ============================================================
# 瞎折腾吧 | VPS 节点管理器
# GitHub: https://github.com/xiazheteng8/xiazheteng-node-manager
# YouTube: https://www.youtube.com/@xiazheteng8
# Telegram: https://t.me/xiazheteng8
#
# 本脚本为管理入口，不会清空防火墙或覆盖系统默认 Xray 配置。
# ============================================================

set -o pipefail
umask 077

APP_NAME="瞎折腾吧 VPS 节点管理器"

XRAY_BIN="/usr/local/bin/xray"
XRAY_CONFIG="/usr/local/etc/xray/node-manager-nocert.json"
XRAY_SERVICE="xray-node-manager-nocert.service"

SUB_SERVICE="node-manager-nocert-subscription.service"
SUB_FILE="/var/lib/node-manager-nocert/subscription.txt"

UPSTREAM_URL="https://raw.githubusercontent.com/yonggekkk/sing-box-yg/main/sb.sh"
UPSTREAM_FILE="/root/sing-box-yg-sb.sh"

BACKUP_ROOT="/root/xiazheteng-node-manager-backups"

# 备份仅处理明确列出的文件，不扫描或覆盖整个系统。
BACKUP_PATHS=(
    "/usr/local/etc/xray/node-manager-nocert.json"
    "/var/lib/node-manager-nocert/subscription.txt"
    "/usr/local/bin/node-manager-nocert-subscription.py"
)

RED=''
GREEN=''
YELLOW=''
BLUE=''
RESET=''

if [[ -t 1 ]]; then
    RED=$'\033[31m'
    GREEN=$'\033[32m'
    YELLOW=$'\033[33m'
    BLUE=$'\033[36m'
    RESET=$'\033[0m'
fi

info() { printf '%s[信息]%s %s\n' "$BLUE" "$RESET" "$*"; }
ok()   { printf '%s[成功]%s %s\n' "$GREEN" "$RESET" "$*"; }
warn() { printf '%s[注意]%s %s\n' "$YELLOW" "$RESET" "$*"; }
err()  { printf '%s[错误]%s %s\n' "$RED" "$RESET" "$*" >&2; }

pause() {
    echo
    read -r -p "按 Enter 返回菜单..." _
}

require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        err "请使用 root 用户运行本脚本。"
        exit 1
    fi
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1
}

show_header() {
    clear 2>/dev/null || true
    echo "============================================================"
    echo "  ${APP_NAME}"
    echo "============================================================"
    echo "  GitHub:  https://github.com/xiazheteng8/xiazheteng-node-manager"
    echo "  YouTube: https://www.youtube.com/@xiazheteng8"
    echo "  Telegram: https://t.me/xiazheteng8"
    echo "------------------------------------------------------------"
}

check_xray_config() {
    echo
    echo "========== Xray 配置检查 =========="

    if [[ ! -x "$XRAY_BIN" ]]; then
        warn "未找到 Xray 程序：$XRAY_BIN"
        pause
        return
    fi

    if [[ ! -f "$XRAY_CONFIG" ]]; then
        warn "未找到指定配置：$XRAY_CONFIG"
        echo "本脚本不会自动创建或覆盖其他 Xray 配置。"
        pause
        return
    fi

    "$XRAY_BIN" run -test -config "$XRAY_CONFIG"
    local rc=$?

    if [[ $rc -eq 0 ]]; then
        ok "Xray 配置语法检查通过。"
    else
        err "配置检查失败，请根据上方错误信息排查。"
    fi

    pause
}

show_service_status() {
    echo
    echo "========== 指定服务状态 =========="

    local services=(
        "$XRAY_SERVICE"
        "$SUB_SERVICE"
    )

    for service in "${services[@]}"; do
        echo
        echo "----- $service -----"

        if systemctl cat "$service" >/dev/null 2>&1; then
            systemctl --no-pager --full status "$service" || true
        else
            warn "系统中不存在此服务：$service"
        fi
    done

    echo
    echo "========== 相关文件 =========="

    for path in "$XRAY_CONFIG" "$SUB_FILE"; do
        if [[ -f "$path" ]]; then
            ls -lh "$path"
            stat -c '权限：%a  所有者：%U:%G' "$path" 2>/dev/null || true
        else
            warn "文件不存在：$path"
        fi
    done

    pause
}

backup_configs() {
    echo
    echo "========== 备份配置 =========="

    local timestamp backup_dir
    timestamp="$(date +%Y%m%d-%H%M%S)"
    backup_dir="${BACKUP_ROOT}/${timestamp}"

    mkdir -p "$backup_dir" || {
        err "无法创建备份目录。"
        pause
        return
    }

    chmod 700 "$BACKUP_ROOT" "$backup_dir" 2>/dev/null || true
    local copied=0

    for path in "${BACKUP_PATHS[@]}"; do
        if [[ -f "$path" ]]; then
            local dest="${backup_dir}${path}"
            mkdir -p "$(dirname "$dest")"
            if cp -a "$path" "$dest"; then
                printf '已备份：%s\n' "$path"
                copied=$((copied + 1))
            else
                warn "备份失败：$path"
            fi
        else
            printf '跳过不存在的文件：%s\n' "$path"
        fi
    done

    if [[ $copied -gt 0 ]]; then
        ok "备份完成：$backup_dir"
        echo "共备份 $copied 个文件。"
        echo "请妥善保管备份，里面可能包含敏感信息。"
    else
        warn "没有找到可备份的文件。"
        rmdir "$backup_dir" 2>/dev/null || true
    fi

    pause
}

list_backups() {
    echo
    echo "========== 现有备份 =========="

    if [[ ! -d "$BACKUP_ROOT" ]]; then
        warn "尚未创建备份。"
        pause
        return
    fi

    find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d \
        -printf '%f\n' 2>/dev/null | sort -r

    pause
}

restore_backup() {
    echo
    echo "========== 恢复配置 =========="
    warn "恢复操作会覆盖对应的现有文件。"
    warn "本功能只恢复本脚本列出的文件，不会自动重启服务。"
    echo

    if [[ ! -d "$BACKUP_ROOT" ]]; then
        err "备份目录不存在：$BACKUP_ROOT"
        pause
        return
    fi

    mapfile -t backups < <(
        find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d \
            -printf '%f\n' 2>/dev/null | sort -r
    )

    if [[ ${#backups[@]} -eq 0 ]]; then
        warn "没有可用备份。"
        pause
        return
    fi

    local i
    for i in "${!backups[@]}"; do
        printf '%d) %s\n' "$((i + 1))" "${backups[$i]}"
    done
    echo "0) 取消"

    local choice
    read -r -p "选择要恢复的备份编号：" choice

    [[ "$choice" == "0" ]] && return

    if ! [[ "$choice" =~ ^[0-9]+$ ]] ||
       (( choice < 1 || choice > ${#backups[@]} )); then
        err "选择无效。"
        pause
        return
    fi

    local backup_dir="${BACKUP_ROOT}/${backups[$((choice - 1))]}"

    echo
    echo "即将从以下目录恢复："
    echo "$backup_dir"
    echo
    read -r -p "确认覆盖对应文件？输入 YES 继续：" confirm

    if [[ "$confirm" != "YES" ]]; then
        warn "已取消恢复。"
        pause
        return
    fi

    for path in "${BACKUP_PATHS[@]}"; do
        local source="${backup_dir}${path}"

        if [[ -f "$source" ]]; then
            mkdir -p "$(dirname "$path")"
            if cp -a "$source" "$path"; then
                ok "已恢复：$path"
            else
                err "恢复失败：$path"
            fi
        fi
    done

    warn "恢复结束。请检查配置语法和服务状态，再决定是否重启相关服务。"
    pause
}

show_subscription_info() {
    echo
    echo "========== 订阅信息 =========="

    if [[ -f "$SUB_FILE" ]]; then
        ls -lh "$SUB_FILE"
        stat -c '权限：%a  所有者：%U:%G' "$SUB_FILE" 2>/dev/null || true
        echo
        echo "出于安全考虑，不直接显示订阅文件中的令牌或节点链接。"
        echo "订阅文件路径：$SUB_FILE"
    else
        warn "订阅文件不存在：$SUB_FILE"
    fi

    echo
    echo "========== 订阅服务状态 =========="

    if systemctl cat "$SUB_SERVICE" >/dev/null 2>&1; then
        systemctl --no-pager --full status "$SUB_SERVICE" || true
    else
        warn "未找到订阅服务：$SUB_SERVICE"
    fi

    pause
}

download_upstream() {
    echo
    echo "========== 下载 / 更新勇哥 Sing-box 脚本 =========="

    if ! need_cmd curl; then
        err "未安装 curl。请先安装 curl 后重试。"
        pause
        return 1
    fi

    local tmp_file
    tmp_file="$(mktemp)" || {
        err "无法创建临时文件。"
        pause
        return 1
    }

    if ! curl -fL --connect-timeout 15 --max-time 180 \
        "$UPSTREAM_URL" -o "$tmp_file"; then
        rm -f "$tmp_file"
        err "下载失败，请检查 VPS 网络或 GitHub 访问情况。"
        pause
        return 1
    fi

    if ! head -n 1 "$tmp_file" | grep -q '^#!'; then
        rm -f "$tmp_file"
        err "下载内容不像 Shell 脚本，已拒绝覆盖本地文件。"
        pause
        return 1
    fi

    if grep -Eq '<p[[:space:]>]|^# 瞎折腾吧｜VPS 节点管理器' "$tmp_file"; then
        rm -f "$tmp_file"
        err "下载内容疑似 Markdown 文档，已拒绝执行。"
        pause
        return 1
    fi

    install -m 700 "$tmp_file" "$UPSTREAM_FILE"
    rm -f "$tmp_file"

    ok "上游脚本已保存到：$UPSTREAM_FILE"
    echo "上游项目：https://github.com/yonggekkk/sing-box-yg"
    pause
}

run_upstream() {
    echo
    echo "========== 勇哥 Sing-box 多协议脚本 =========="
    warn "这是独立的第三方脚本，可能会安装软件、修改服务、端口或防火墙规则。"
    warn "执行前请备份，并确认其操作不会影响网站、邮件及已有节点。"
    echo

    read -r -p "是否先下载/更新上游脚本？[Y/n]：" answer
    answer="${answer:-Y}"

    case "$answer" in
        Y|y|YES|yes)
            download_upstream
            ;;
        N|n|NO|no)
            ;;
        *)
            warn "输入无效，已取消。"
            pause
            return
            ;;
    esac

    if [[ ! -s "$UPSTREAM_FILE" ]]; then
        err "上游脚本不存在，请先执行下载/更新。"
        pause
        return
    fi

    if ! head -n 1 "$UPSTREAM_FILE" | grep -q '^#!'; then
        err "上游文件格式异常，拒绝执行。"
        pause
        return
    fi

    echo
    read -r -p "确认执行上游脚本？输入 YES 继续：" confirm

    if [[ "$confirm" != "YES" ]]; then
        warn "已取消。"
        pause
        return
    fi

    bash "$UPSTREAM_FILE"
    local rc=$?

    echo
    if [[ $rc -eq 0 ]]; then
        ok "上游脚本已退出。"
    else
        warn "上游脚本退出码：$rc"
    fi

    pause
}

show_menu() {
    show_header
    cat <<'MENU'
  1. 启动勇哥 Sing-box 多协议脚本
  2. 下载 / 更新勇哥 Sing-box 脚本
  3. 检查指定的 Xray 配置
  4. 查看相关服务状态
  5. 备份配置
  6. 查看现有备份
  7. 恢复配置备份
  8. 查看订阅信息
  0. 退出

------------------------------------------------------------
注意：本脚本不会自动清空防火墙，也不会操作系统默认
      /usr/local/etc/xray/config.json 或 xray.service。
------------------------------------------------------------
MENU
}

main() {
    require_root
    mkdir -p "$BACKUP_ROOT"
    chmod 700 "$BACKUP_ROOT" 2>/dev/null || true

    while true; do
        show_menu
        local choice
        read -r -p "请输入选项 [0-8]：" choice

        case "$choice" in
            1) run_upstream ;;
            2) download_upstream ;;
            3) check_xray_config ;;
            4) show_service_status ;;
            5) backup_configs ;;
            6) list_backups ;;
            7) restore_backup ;;
            8) show_subscription_info ;;
            0)
                echo "感谢使用「瞎折腾吧｜VPS 节点管理器」。"
                exit 0
                ;;
            *)
                warn "无效选项，请输入 0-8。"
                sleep 1
                ;;
        esac
    done
}

main "$@"
