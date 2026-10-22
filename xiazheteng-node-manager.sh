
cat > /root/xiazheteng-node-manager.sh <<'SCRIPT_EOF'
#!/usr/bin/env bash

# ============================================================
# 瞎折腾吧 | 3x-ui 节点管理器
# Version: 2.1.0
# Ubuntu 22.04 / Debian
# ============================================================

umask 077

VERSION="2.1.0"
LOG_DIR="/var/log/xiazheteng-node-manager"
BACKUP_DIR="/var/backups/xiazheteng-node-manager"
LOG_FILE="$LOG_DIR/run.log"

mkdir -p "$LOG_DIR" "$BACKUP_DIR" 2>/dev/null || {
    echo "[错误] 无法创建日志或备份目录。"
    exit 1
}

# 不使用 exec 重定向标准输入，避免影响菜单交互。
log() {
    local msg="$*"
    printf '%s %s\n' "[$(date '+%F %T')]" "$msg" >> "$LOG_FILE"
    printf '%s\n' "$msg"
}

pause() {
    echo
    if [[ -r /dev/tty ]]; then
        read -r -p "按回车继续..." _ </dev/tty || true
    else
        echo "[提示] 当前没有可交互终端。"
    fi
}

is_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        echo "[错误] 请使用 root 用户运行。"
        return 1
    fi
}

on_error() {
    local rc=$?
    log "[错误] 命令失败，退出码=$rc，位置=${BASH_LINENO[0]:-未知}"
    log "[提示] 日志文件：$LOG_FILE"
    return 0
}
trap on_error ERR

install_dependencies() {
    local missing=()
    local pkg

    command -v curl >/dev/null 2>&1 || missing+=(curl)
    command -v jq >/dev/null 2>&1 || missing+=(jq)
    command -v openssl >/dev/null 2>&1 || missing+=(openssl)
    command -v uuidgen >/dev/null 2>&1 || missing+=(uuid-runtime)
    command -v ss >/dev/null 2>&1 || missing+=(iproute2)
    command -v systemctl >/dev/null 2>&1 || missing+=(systemd)

    dpkg-query -W -f='${Status}' ca-certificates 2>/dev/null \
        | grep -q 'install ok installed' \
        || missing+=(ca-certificates)

    if [[ "${#missing[@]}" -eq 0 ]]; then
        log "[成功] 所需依赖均已安装。"
        return 0
    fi

    # 去重
    mapfile -t missing < <(printf '%s\n' "${missing[@]}" | sort -u)

    log "[信息] 需要安装依赖：${missing[*]}"

    if ! command -v apt-get >/dev/null 2>&1; then
        log "[错误] 当前系统没有 apt-get，无法自动安装依赖。"
        return 1
    fi

    log "[信息] 正在更新软件包索引..."
    if ! apt-get update; then
        log "[错误] apt-get update 失败。"
        return 1
    fi

    log "[信息] 正在安装依赖..."
    if ! DEBIAN_FRONTEND=noninteractive apt-get install -y \
        curl ca-certificates jq openssl uuid-runtime iproute2; then
        log "[错误] 依赖安装失败。"
        return 1
    fi

    # 安装后重新检查
    local failed=()
    command -v curl >/dev/null 2>&1 || failed+=(curl)
    command -v jq >/dev/null 2>&1 || failed+=(jq)
    command -v openssl >/dev/null 2>&1 || failed+=(openssl)
    command -v uuidgen >/dev/null 2>&1 || failed+=(uuidgen)
    command -v ss >/dev/null 2>&1 || failed+=(ss)

    if [[ "${#failed[@]}" -gt 0 ]]; then
        log "[错误] 以下命令安装后仍不可用：${failed[*]}"
        return 1
    fi

    log "[成功] 依赖安装并复检通过。"
    return 0
}

detect_xui() {
    command -v x-ui >/dev/null 2>&1 && return 0

    systemctl list-unit-files --no-legend 2>/dev/null \
        | awk '{print $1}' \
        | grep -qx 'x-ui.service' && return 0

    [[ -x /usr/local/x-ui/x-ui ]] && return 0

    return 1
}

show_status() {
    echo
    echo "========== 3x-ui 状态 =========="

    if detect_xui; then
        echo "[检测] 已发现 3x-ui。"
    else
        echo "[提示] 未发现常见的 3x-ui 安装路径。"
    fi

    if systemctl list-unit-files --no-legend 2>/dev/null \
        | awk '{print $1}' | grep -qx 'x-ui.service'; then
        systemctl --no-pager --full status x-ui || true
    else
        echo "[提示] 未找到 x-ui.service。"
    fi

    echo
    echo "========== TCP 监听端口 =========="
    if command -v ss >/dev/null 2>&1; then
        ss -lntp || true
    else
        echo "[提示] ss 命令尚不可用。"
    fi
}

show_logs() {
    echo
    echo "========== 3x-ui 服务日志 =========="

    if systemctl list-unit-files --no-legend 2>/dev/null \
        | awk '{print $1}' | grep -qx 'x-ui.service'; then
        journalctl -u x-ui -n 100 --no-pager || true
    else
        echo "[提示] 未找到 x-ui.service。"
    fi
}

restart_xui() {
    echo
    if ! detect_xui; then
        log "[错误] 未检测到 3x-ui，取消重启。"
        return 1
    fi

    if ! systemctl list-unit-files --no-legend 2>/dev/null \
        | awk '{print $1}' | grep -qx 'x-ui.service'; then
        log "[错误] 未找到 x-ui.service，无法通过 systemd 重启。"
        return 1
    fi

    if systemctl restart x-ui; then
        sleep 2
        log "[成功] 已执行 3x-ui 重启。"
        systemctl --no-pager --full status x-ui || true
    else
        log "[错误] 3x-ui 重启失败。"
        return 1
    fi
}

backup_xui() {
    local stamp dest
    local paths=()

    stamp="$(date '+%Y%m%d-%H%M%S')"
    dest="$BACKUP_DIR/xui-backup-$stamp.tar.gz"

    [[ -e /etc/x-ui ]] && paths+=(etc/x-ui)
    [[ -e /usr/local/x-ui ]] && paths+=(usr/local/x-ui)

    if [[ "${#paths[@]}" -eq 0 ]]; then
        log "[错误] 未找到 /etc/x-ui 或 /usr/local/x-ui，无法创建备份。"
        return 1
    fi

    if tar -czf "$dest" -C / "${paths[@]}"; then
        chmod 600 "$dest"
        log "[成功] 配置备份已保存：$dest"
    else
        rm -f "$dest"
        log "[错误] 备份失败。"
        return 1
    fi
}

show_ip_info() {
    echo
    echo "========== 本机网络 =========="

    if command -v ip >/dev/null 2>&1; then
        ip -brief address || true
        echo
        ip route show default || true
    else
        hostname -I 2>/dev/null || true
    fi

    echo
    echo "========== 公网 IPv4 =========="
    if command -v curl >/dev/null 2>&1; then
        curl -4 -fsS --connect-timeout 5 --max-time 10 \
            https://api.ipify.org || echo "[提示] 公网 IPv4 查询失败。"
        echo
    else
        echo "[提示] curl 尚未安装。"
    fi
}

show_manager_logs() {
    echo
    echo "========== 管理器日志 =========="
    if [[ -f "$LOG_FILE" ]]; then
        tail -n 80 "$LOG_FILE"
    else
        echo "[提示] 尚无日志。"
    fi
}

show_menu() {
    echo
    echo "============================================================"
    echo "       瞎折腾吧 | 3x-ui 节点管理器 v$VERSION"
    echo "============================================================"
    echo "  1. 检查并安装依赖"
    echo "  2. 查看 3x-ui 状态与监听端口"
    echo "  3. 查看 3x-ui 服务日志"
    echo "  4. 重启 3x-ui"
    echo "  5. 备份 3x-ui 配置"
    echo "  6. 查看管理器日志"
    echo "  7. 查看本机网络信息"
    echo "  0. 退出"
    echo "============================================================"
}

main_menu() {
    local choice

    while true; do
        show_menu

        if [[ ! -r /dev/tty ]]; then
            log "[错误] 无法打开交互终端，菜单无法读取输入。"
            return 1
        fi

        if ! IFS= read -r -p "请输入选项 [0-7]：" choice </dev/tty; then
            echo
            log "[错误] 无法从终端读取输入。"
            log "[提示] 请在 SSH 交互终端中运行：bash $0"
            return 1
        fi

        case "$choice" in
            1)
                install_dependencies || true
                pause
                ;;
            2)
                show_status
                pause
                ;;
            3)
                show_logs
                pause
                ;;
            4)
                restart_xui || true
                pause
                ;;
            5)
                backup_xui || true
                pause
                ;;
            6)
                show_manager_logs
                pause
                ;;
            7)
                show_ip_info
                pause
                ;;
            0)
                log "[信息] 已退出节点管理器。"
                return 0
                ;;
            *)
                echo "[提示] 无效选项，请输入 0-7。"
                ;;
        esac
    done
}

main() {
    if ! is_root; then
        return 1
    fi

    log "============================================================"
    log "瞎折腾吧 | 3x-ui 节点管理器 v$VERSION"
    log "[信息] 开始初始化..."

    if ! install_dependencies; then
        log "[警告] 依赖检查未通过，但仍保留菜单供查看日志。"
    fi

    log "[成功] 初始化阶段结束，正在进入菜单..."
    main_menu
}

main "$@"
SCRIPT_EOF

chmod 700 /root/xiazheteng-node-manager.sh

echo "========== Bash 语法检查 =========="
if bash -n /root/xiazheteng-node-manager.sh; then
    echo "[成功] 语法检查通过。"
else
    echo "[错误] 语法检查失败，停止运行。"
    exit 1
fi

echo
echo "========== 启动管理器 =========="
bash /root/xiazheteng-node-manager.sh
