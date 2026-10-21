
#!/usr/bin/env bash
# ============================================================
# 瞎折腾吧 VPS 多协议节点统一管理器
# Xray 无证书实例 + Sing-box-yg 五协议模块
#
# 原有 Xray:
#   Config: /usr/local/etc/xray/node-manager-nocert.json
#   Service: xray-node-manager-nocert.service
#   Subscription: /var/lib/node-manager-nocert/subscription.txt
#
# Upstream:
#   https://github.com/yonggekkk/sing-box-yg
#
# 注意：Sing-box-yg 保留为独立模块，不合并两种内核的 JSON。
# ============================================================

set -Eeuo pipefail
umask 077

APP_NAME="瞎折腾吧 VPS 节点管理器"
BASE="/opt/xiazheteng-node-manager"
UPSTREAM_DIR="$BASE/upstream"
UPSTREAM_SCRIPT="$UPSTREAM_DIR/sb.sh"
UPSTREAM_URL="https://raw.githubusercontent.com/yonggekkk/sing-box-yg/main/sb.sh"

XRAY="/usr/local/bin/xray"
XRAY_CONFIG="/usr/local/etc/xray/node-manager-nocert.json"
XRAY_SERVICE="xray-node-manager-nocert.service"
SUB_SERVICE="node-manager-nocert-subscription.service"
SUB_FILE="/var/lib/node-manager-nocert/subscription.txt"
BACKUP_DIR="/root/node-manager-backups"

need_root() {
    if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
        echo "请使用 root 运行："
        echo "sudo bash /root/xiazheteng-node-manager.sh"
        exit 1
    fi
}

pause() {
    echo
    read -r -p "按回车键返回菜单……" _
}

line() {
    printf '%s\n' '============================================================'
}

init_dirs() {
    mkdir -p "$BASE" "$UPSTREAM_DIR" "$BACKUP_DIR"
    chmod 700 "$BASE" "$UPSTREAM_DIR" "$BACKUP_DIR"
}

check_xray_files() {
    [[ -x "$XRAY" ]] || {
        echo "未找到 Xray：$XRAY"
        return 1
    }
    [[ -f "$XRAY_CONFIG" ]] || {
        echo "未找到无证书配置：$XRAY_CONFIG"
        return 1
    }
}

backup_xray() {
    check_xray_files || return 1
    mkdir -p "$BACKUP_DIR"
    chmod 700 "$BACKUP_DIR"

    local stamp
    stamp="$(date +%Y%m%d-%H%M%S)"

    cp -a "$XRAY_CONFIG" \
        "$BACKUP_DIR/node-manager-nocert-$stamp.json"

    if [[ -f "$SUB_FILE" ]]; then
        cp -a "$SUB_FILE" \
            "$BACKUP_DIR/subscription-$stamp.txt"
    fi

    echo "Xray 配置备份完成。"
    echo "备份目录：$BACKUP_DIR"
}

check_xray_config() {
    check_xray_files || return 1
    line
    echo "检查现有无证书 Xray 配置……"
    "$XRAY" run -test -config "$XRAY_CONFIG"
    local result=$?
    line
    return "$result"
}

show_status() {
    line
    echo "【现有无证书 Xray 服务】"
    systemctl --no-pager --full status "$XRAY_SERVICE" || true

    echo
    echo "【现有订阅服务】"
    systemctl --no-pager --full status "$SUB_SERVICE" || true

    echo
    echo "【默认 Xray 服务】"
    echo "以下仅显示状态，不会操作默认服务。"
    systemctl is-active xray.service 2>/dev/null || true

    echo
    echo "【端口监听】"
    ss -lntup 2>/dev/null |
        grep -E '(:80|:443|:8388|:18080)([[:space:]]|$)' || true

    echo
    echo "【现有节点配置检查】"
    if [[ -x "$XRAY" && -f "$XRAY_CONFIG" ]]; then
        "$XRAY" run -test -config "$XRAY_CONFIG" || true
    else
        echo "现有 Xray 配置或程序不存在。"
    fi
    line
}

download_upstream() {
    init_dirs

    if ! command -v curl >/dev/null 2>&1; then
        echo "缺少 curl。请先安装 curl 后再试。"
        return 1
    fi

    local tmp
    tmp="$(mktemp "$UPSTREAM_DIR/sb.sh.XXXXXX")"

    echo "正在下载勇哥公开仓库的 VPS 脚本……"
    if ! curl -fL --connect-timeout 15 --max-time 180 \
        --retry 2 "$UPSTREAM_URL" -o "$tmp"; then
        rm -f "$tmp"
        echo "下载失败，请检查网络或稍后重试。"
        return 1
    fi

    if [[ ! -s "$tmp" ]] || ! head -n 1 "$tmp" | grep -q 'bash'; then
        rm -f "$tmp"
        echo "下载文件校验失败，已取消。"
        return 1
    fi

    chmod 700 "$tmp"
    mv -f "$tmp" "$UPSTREAM_SCRIPT"

    echo "已保存：$UPSTREAM_SCRIPT"
    echo "来源：$UPSTREAM_URL"
}

run_upstream() {
    init_dirs

    if [[ ! -s "$UPSTREAM_SCRIPT" ]]; then
        download_upstream || return 1
    else
        echo "当前本地模块：$UPSTREAM_SCRIPT"
        echo "如需获取上游最新版本，请先使用“下载/更新勇哥模块”。"
    fi

    echo
    line
    echo "即将启动 Sing-box-yg 独立模块。"
    echo
    echo "该模块支持的功能以其上游版本为准，包括："
    echo "  - VLESS REALITY Vision"
    echo "  - VMess WS/TLS 或 Argo"
    echo "  - Hysteria 2"
    echo "  - TUIC v5"
    echo "  - AnyTLS"
    echo "  - 上游版本所提供的证书、订阅和隧道管理功能"
    echo
    echo "重要保护提示："
    echo "  1. 本管理器不会主动停止现有 Xray 服务。"
    echo "  2. 上游脚本是独立安装程序，仍可能修改系统依赖、防火墙或服务。"
    echo "  3. 证书申请可能需要 80/443 端口；你当前的 Nginx/邮件网站需先确认兼容性。"
    echo "  4. 不要在未确认端口和配置的情况下选择覆盖现有服务的操作。"
    line

    local answer
    read -r -p "确认运行上游脚本？输入 YES 继续：" answer
    [[ "$answer" == "YES" ]] || {
        echo "已取消。"
        return 0
    }

    bash "$UPSTREAM_SCRIPT"
    local result=$?

    echo
    echo "上游脚本退出，退出码：$result"
    echo "返回前请确认现有 Xray 服务仍正常。"
    return 0
}

update_upstream() {
    echo "更新操作只下载脚本，不会自动执行。"
    download_upstream || return 1
    echo
    echo "下载完成。之后可从菜单启动上游模块。"
}

show_subscription_info() {
    line
    echo "订阅文件：$SUB_FILE"
    if [[ -f "$SUB_FILE" ]]; then
        stat -c '权限=%a 文件大小=%s 字节 修改时间=%y' "$SUB_FILE"
    else
        echo "订阅文件不存在。"
    fi

    echo
    echo "订阅服务状态："
    systemctl is-active "$SUB_SERVICE" 2>/dev/null || true

    echo
    echo "订阅服务配置路径："
    systemctl show "$SUB_SERVICE" -p FragmentPath -p ExecStart \
        --no-pager 2>/dev/null || true

    echo
    echo "订阅 URL 使用格式："
    echo "http://服务器地址:订阅端口/订阅令牌"
    echo "本菜单不会打印令牌，避免终端截图意外泄露。"
    line
}

show_backups() {
    line
    echo "备份目录：$BACKUP_DIR"
    if [[ -d "$BACKUP_DIR" ]]; then
        ls -lht "$BACKUP_DIR" | head -n 30
    else
        echo "尚无备份。"
    fi
    line
}

restore_xray_backup() {
    check_xray_files || return 1

    mapfile -t backups < <(
        find "$BACKUP_DIR" -maxdepth 1 -type f \
            -name 'node-manager-nocert-*.json' -printf '%T@ %p\n' |
        sort -nr | awk '{$1=""; sub(/^ /,""); print}'
    )

    if [[ ${#backups[@]} -eq 0 ]]; then
        echo "没有找到 Xray 配置备份。"
        return 1
    fi

    echo "可恢复的 Xray 配置备份："
    local i=1
    local f
    for f in "${backups[@]}"; do
        echo "$i. $f"
        ((i+=1))
    done

    echo
    read -r -p "输入编号恢复，输入 0 取消：" choice
    [[ "$choice" =~ ^[0-9]+$ ]] || {
        echo "无效编号。"
        return 1
    }
    (( choice >= 1 && choice <= ${#backups[@]} )) || {
        echo "已取消或编号超出范围。"
        return 1
    }

    local selected="${backups[$((choice-1))]}"
    echo
    echo "即将恢复：$selected"
    echo "此操作只恢复无证书 Xray 配置，不恢复订阅文件。"
    read -r -p "输入 RESTORE 确认：" answer
    [[ "$answer" == "RESTORE" ]] || {
        echo "已取消。"
        return 0
    }

    # 恢复前再保存一份当前配置。
    backup_xray || return 1
    cp -a "$selected" "$XRAY_CONFIG"

    if ! "$XRAY" run -test -config "$XRAY_CONFIG"; then
        echo "恢复后的配置校验失败。请从备份目录手动恢复。"
        return 1
    fi

    echo "配置检查通过。现在重启独立 Xray 服务。"
    systemctl restart "$XRAY_SERVICE"
    systemctl --no-pager --full status "$XRAY_SERVICE"
}

show_menu() {
    clear 2>/dev/null || true
    line
    printf '       %s\n' "$APP_NAME"
    line
    cat <<'MENU'
1. 启动勇哥 Sing-box 多协议模块
2. 下载/更新勇哥模块（只下载，不执行）
3. 检查现有无证书 Xray 配置
4. 查看现有 Xray / 订阅服务 / 端口状态
5. 备份现有无证书 Xray 配置和订阅文件
6. 查看备份文件
7. 恢复一份无证书 Xray 配置备份
8. 查看订阅文件与服务信息
0. 退出

说明：
- 原有 Xray 与 Sing-box 使用独立配置和服务。
- 勇哥模块的证书、五协议、Argo 等功能由上游脚本管理。
- 本管理器不会自动合并两套订阅，也不会自动改写 Nginx。
MENU
    line
}

main() {
    need_root
    init_dirs

    while true; do
        show_menu
        read -r -p "请选择 [0-8]：" choice

        case "$choice" in
            1) run_upstream; pause ;;
            2) update_upstream; pause ;;
            3)
                if check_xray_config; then
                    echo "配置检查通过。"
                else
                    echo "配置检查失败，请保留输出以便排查。"
                fi
                pause
                ;;
            4) show_status; pause ;;
            5) backup_xray; pause ;;
            6) show_backups; pause ;;
            7) restore_xray_backup; pause ;;
            8) show_subscription_info; pause ;;
            0) exit 0 ;;
            *) echo "无效选项。"; sleep 1 ;;
        esac
    done
}

main "$@"
