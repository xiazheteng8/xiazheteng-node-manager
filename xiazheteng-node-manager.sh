
cat > /root/xiazheteng-node-manager.sh <<'SCRIPT_EOF'
#!/usr/bin/env bash

# ============================================================
# 瞎折腾吧 | 3x-ui 节点管理器
# Ubuntu 22.04 / Debian
# 单文件版本
# ============================================================

set -o pipefail
umask 077

VERSION="2.0.0"
SCRIPT_PATH="/root/xiazheteng-node-manager.sh"
LOG_DIR="/var/log/xiazheteng-node-manager"
BACKUP_DIR="/var/backups/xiazheteng-node-manager"

mkdir -p "$LOG_DIR" "$BACKUP_DIR" 2>/dev/null || true
LOG_FILE="$LOG_DIR/run.log"

# 记录运行日志，同时保留终端输出
exec > >(tee -a "$LOG_FILE") 2>&1

on_error() {
    local rc=$?
    echo
    echo "============================================================"
    echo "[错误] 脚本执行失败"
    echo "[错误码] $rc"
    echo "[脚本行号] ${BASH_LINENO[0]:-未知}"
    echo "[日志文件] $LOG_FILE"
    echo "============================================================"
    echo "按回车返回菜单..."
    read -r _ || true
    return 0
}
trap on_error ERR

pause() {
    echo
    read -r -p "按回车继续..." _ || true
}

line() {
    printf '%s\n' '------------------------------------------------------------'
}

is_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "[错误] 请使用 root 用户运行。"
        exit 1
    fi
}

need_commands() {
    local missing=()
    local cmd

    for cmd in curl ca-certificates jq openssl uuidgen ss systemctl; do
        case "$cmd" in
            ca-certificates)
                dpkg -s ca-certificates >/dev/null 2>&1 || missing+=("ca-certificates")
                ;;
            uuidgen)
                command -v uuidgen >/dev/null 2>&1 || missing+=("uuid-runtime")
                ;;
            ss)
                command -v ss >/dev/null 2>&1 || missing+=("iproute2")
                ;;
            *)
                command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
                ;;
        esac
    done

    if [ "${#missing[@]}" -eq 0 ]; then
        echo "[成功] 依赖检查通过。"
        return 0
    fi

    echo "[信息] 需要安装以下依赖：${missing[*]}"

    if ! command -v apt-get >/dev/null 2>&1; then
        echo "[错误] 当前系统没有 apt-get，请手动安装依赖。"
        return 1
    fi

    echo "[信息] 正在更新软件包索引..."
    if ! apt-get update; then
        echo "[错误] apt-get update 失败。"
        return 1
    fi

    echo "[信息] 正在安装依赖..."
    if ! apt-get install -y curl ca-certificates jq openssl uuid-runtime iproute2; then
        echo "[错误] 依赖安装失败。"
        return 1
    fi

    echo "[成功] 依赖安装完成。"
}

detect_xui() {
    if command -v x-ui >/dev/null 2>&1; then
        return 0
    fi

    if systemctl list-unit-files 2>/dev/null | grep -q '^x-ui\.service'; then
        return 0
    fi

    if [ -x /usr/local/x-ui/x-ui ]; then
        return 0
    fi

    return 1
}

show_xui_status() {
    line
    echo "3x-ui 状态"
    line

    if detect_xui; then
        echo "[检测] 已发现 3x-ui 安装。"
    else
        echo "[检测] 未发现常见的 3x-ui 安装路径或服务。"
    fi

    if systemctl list-unit-files 2>/dev/null | grep -q '^x-ui\.service'; then
        systemctl --no-pager --full status x-ui || true
    else
        echo "[提示] 未找到 x-ui.service。"
    fi

    echo
    echo "监听端口："
    if command -v ss >/dev/null 2>&1; then
        ss -lntp || true
    else
        echo "[提示] 未安装 ss 命令。"
    fi
}

show_xui_logs() {
    line
    echo "3x-ui 最近日志"
    line

    if ! systemctl list-unit-files 2>/dev/null | grep -q '^x-ui\.service'; then
        echo "[错误] 未找到 x-ui.service。"
        return 1
    fi

    journalctl -u x-ui -n 100 --no-pager || true
}

restart_xui() {
    line
    echo "重启 3x-ui"
    line

    if ! detect_xui; then
        echo "[错误] 未检测到 3x-ui。"
        return 1
    fi

    if ! systemctl list-unit-files 2>/dev/null | grep -q '^x-ui\.service'; then
        echo "[错误] 未找到 x-ui.service，未执行重启。"
        return 1
    fi

    if systemctl restart x-ui; then
        sleep 2
        systemctl --no-pager --full status x-ui || true
        echo "[成功] 已发送重启命令。"
    else
        echo "[错误] 重启失败，请查看日志。"
        return 1
    fi
}

backup_xui() {
    line
    echo "备份 3x-ui 配置"
    line

    local stamp dest
    stamp="$(date +%Y%m%d-%H%M%S)"
    dest="$BACKUP_DIR/xui-backup-$stamp.tar.gz"

    local paths=()
    local p

    for p in /etc/x-ui /usr/local/x-ui; do
        if [ -e "$p" ]; then
            paths+=("$p")
        fi
    done

    if [ "${#paths[@]}" -eq 0 ]; then
        echo "[错误] 没有找到常见的配置目录。"
        echo "未创建备份。"
        return 1
    fi

    if tar -czf "$dest" "${paths[@]}"; then
        chmod 600 "$dest"
        echo "[成功] 备份完成：$dest"
    else
        echo "[错误] 备份失败。"
        rm -f "$dest"
        return 1
    fi
}

show_menu() {
    clear 2>/dev/null || true
    echo
    echo "============================================================"
    echo "       瞎折腾吧 | 3x-ui 节点管理器 v$VERSION"
    echo "============================================================"
    echo "  1. 检查运行环境与依赖"
    echo "  2. 查看 3x-ui 状态和监听端口"
    echo "  3. 查看 3x-ui 最近日志"
    echo "  4. 重启 3x-ui"
    echo "  5. 备份 3x-ui 配置"
    echo "  6. 查看脚本日志"
    echo "  7. 查看本机 IP 信息"
    echo "  0. 退出"
    echo "============================================================"
}

show_ip_info() {
    line
    echo "本机网络信息"
    line

    echo "IPv4 地址："
    hostname -I 2>/dev/null || true

    echo
    echo "默认路由："
    ip route show default 2>/dev/null || true

    echo
    echo "公网 IP 检测："
    if command -v curl >/dev/null 2>&1; then
        curl -4 --connect-timeout 5 --max-time 10 -fsS https://api.ipify.org \
            || echo "[提示] IPv4 公网 IP 查询失败。"
        echo
    fi
}

show_script_log() {
    line
    echo "脚本日志"
    line
    if [ -f "$LOG_FILE" ]; then
        tail -n 100 "$LOG_FILE" || true
    else
        echo "[提示] 日志文件尚未创建。"
    fi
}

main_menu() {
    local choice

    while true; do
        show_menu
        read -r -p "请输入选项 [0-7]：" choice || choice="0"

        case "$choice" in
            1)
                need_commands
                pause
                ;;
            2)
                show_xui_status
                pause
                ;;
            3)
                show_xui_logs
                pause
                ;;
            4)
                restart_xui
                pause
                ;;
            5)
                backup_xui
                pause
                ;;
            6)
                show_script_log
                pause
                ;;
            7)
                show_ip_info
                pause
                ;;
            0)
                echo "已退出节点管理器。"
                return 0
                ;;
            *)
                echo "[提示] 无效选项，请输入 0-7。"
                sleep 1
                ;;
        esac
    done
}

main() {
    is_root

    echo "============================================================"
    echo " 瞎折腾吧 | 3x-ui 节点管理器 v$VERSION"
    echo "============================================================"
    echo "[信息] 正在检查运行环境..."

    if ! need_commands; then
        echo
        echo "[错误] 依赖检查未通过。"
        echo "[提示] 可查看日志：$LOG_FILE"
        pause
    fi

    echo
    echo "[成功] 初始化阶段结束，正在进入菜单..."
    sleep 1
    main_menu
}

main "$@"
SCRIPT_EOF

chmod 700 /root/xiazheteng-node-manager.sh
bash -n /root/xiazheteng-node-manager.sh || exit 1
bash /root/xiazheteng-node-manager.sh
