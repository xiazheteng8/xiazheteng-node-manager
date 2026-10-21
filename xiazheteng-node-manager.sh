#!/usr/bin/env bash
# ============================================================
# xiazhetng8 | Sing-box 节点管理器
#
# GitHub:   https://github.com/xiazheteng8/xiazheteng-node-manager
# YouTube:  https://www.youtube.com/@xiazheteng8
# Telegram: https://t.me/xiazheteng8
# ============================================================

set -Eeuo pipefail
export LANG=C.UTF-8
export LC_ALL=C.UTF-8
umask 077

readonly BRAND="xiazhetng8"
readonly REPO="https://github.com/xiazheteng8/xiazheteng-node-manager"
readonly RAW_URL="https://raw.githubusercontent.com/xiazheteng8/xiazheteng-node-manager/main/sing-box-manager.sh"

readonly BASE="/etc/xiazheteng-singbox"
readonly APPDIR="/usr/local/lib/xiazheteng-singbox"
readonly BIN="$APPDIR/sing-box"
readonly SCRIPT_FILE="$APPDIR/sing-box-manager.sh"
readonly CONFIG="$BASE/config.json"
readonly NODE="$BASE/node.txt"
readonly SUB="$BASE/subscribe.txt"
readonly SERVICE="xiazheteng-singbox"
readonly UNIT="/etc/systemd/system/${SERVICE}.service"
readonly SHORTCUT="/usr/local/bin/x"

# -------------------- 基础函数 --------------------

red()    { printf '\033[31m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
blue()   { printf '\033[36m%s\033[0m\n' "$*"; }
line()   { printf '%s\n' '============================================================'; }

pause() {
    read -r -p "按回车继续..." _ || true
}

die() {
    red "错误：$*"
    return 1
}

need_root() {
    if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
        die "请使用 root 权限运行此脚本。"
        return 1
    fi
}

has() {
    command -v "$1" >/dev/null 2>&1
}

detect_os() {
    if [[ ! -r /etc/os-release ]]; then
        die "无法识别当前操作系统。"
        return 1
    fi

    # shellcheck disable=SC1091
    . /etc/os-release

    case "${ID:-}" in
        ubuntu|debian) ;;
        *)
            die "当前版本仅支持 Ubuntu / Debian。"
            return 1
            ;;
    esac

    if ! has systemctl; then
        die "当前系统没有 systemd，无法安装服务。"
        return 1
    fi
}

# -------------------- 依赖安装 --------------------

install_deps() {
    export DEBIAN_FRONTEND=noninteractive

    apt-get update
    apt-get install -y \
        curl \
        jq \
        openssl \
        ca-certificates \
        tar \
        coreutils \
        python3 \
        iproute2
}

# -------------------- Sing-box 内核 --------------------

get_arch() {
    case "$(uname -m)" in
        x86_64|amd64)
            ARCH="amd64"
            ;;
        aarch64|arm64)
            ARCH="arm64"
            ;;
        *)
            die "暂不支持的 CPU 架构：$(uname -m)"
            return 1
            ;;
    esac
}

install_kernel() {
    get_arch || return 1

    mkdir -p "$APPDIR"

    local tag version url tmp candidate
    tmp="$(mktemp -d)"

    tag="$(
        curl -fsSL --retry 3 \
            https://api.github.com/repos/SagerNet/sing-box/releases/latest \
        | jq -er '.tag_name'
    )" || {
        rm -rf "$tmp"
        die "获取 Sing-box 最新版本失败。"
        return 1
    }

    version="${tag#v}"

    if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]]; then
        rm -rf "$tmp"
        die "获取到的版本号格式异常：$version"
        return 1
    fi

    url="https://github.com/SagerNet/sing-box/releases/download/v${version}/sing-box-${version}-linux-${ARCH}.tar.gz"

    yellow "正在下载 Sing-box ${version}（${ARCH}）..."

    if ! curl -fL --retry 3 "$url" -o "$tmp/sing-box.tar.gz"; then
        rm -rf "$tmp"
        die "下载 Sing-box 失败。请检查网络或 GitHub 访问情况。"
        return 1
    fi

    if ! tar -xzf "$tmp/sing-box.tar.gz" -C "$tmp"; then
        rm -rf "$tmp"
        die "Sing-box 压缩包解压失败。"
        return 1
    fi

    candidate="$(
        find "$tmp" -type f -name sing-box -perm /111 -print -quit
    )"

    if [[ -z "$candidate" ]]; then
        rm -rf "$tmp"
        die "压缩包中没有找到 Sing-box 可执行文件。"
        return 1
    fi

    # 下载、解压成功后才替换本项目自己的内核。
    install -m 0755 "$candidate" "$BIN"
    rm -rf "$tmp"

    "$BIN" version
}

# -------------------- 端口与公网地址 --------------------

port_is_used() {
    local port="$1"

    if ! has ss; then
        return 1
    fi

    ss -H -lntup 2>/dev/null \
        | awk '{print $5}' \
        | grep -Eq "[:.]${port}$"
}

random_port() {
    local port

    while true; do
        port="$(shuf -i 20000-60000 -n 1)"

        if ! port_is_used "$port"; then
            printf '%s' "$port"
            return 0
        fi
    done
}

get_public_ipv4() {
    local ip

    ip="$(
        curl -4fsS --max-time 8 https://api.ipify.org 2>/dev/null || true
    )"

    if [[ -z "$ip" ]]; then
        ip="$(
            curl -4fsS --max-time 8 https://ipv4.icanhazip.com 2>/dev/null \
                | tr -d '[:space:]' || true
        )"
    fi

    if [[ -z "$ip" ]]; then
        die "无法获取公网 IPv4 地址，请检查 VPS 网络。"
        return 1
    fi

    if ! python3 - "$ip" <<'PY'
import ipaddress
import sys

try:
    ip = ipaddress.ip_address(sys.argv[1])
    sys.exit(0 if ip.version == 4 and ip.is_global else 1)
except ValueError:
    sys.exit(1)
PY
    then
        die "获取到的地址不是有效的公网 IPv4：$ip"
        return 1
    fi

    printf '%s' "$ip"
}

# -------------------- 配置与节点生成 --------------------

create_node() {
    local ip port uuid sni sid keys private public node

    mkdir -p "$BASE"
    chmod 700 "$BASE"

    ip="$(get_public_ipv4)" || return 1
    port="$(random_port)"
    uuid="$(cat /proc/sys/kernel/random/uuid)"
    sni="www.microsoft.com"
    sid="$(openssl rand -hex 8)"

    keys="$("$BIN" generate reality-keypair 2>&1)" || {
        die "Reality 密钥生成失败。"
        return 1
    }

    private="$(
        printf '%s\n' "$keys" \
            | sed -nE 's/^PrivateKey:[[:space:]]*//p' \
            | head -n 1
    )"

    public="$(
        printf '%s\n' "$keys" \
            | sed -nE 's/^PublicKey:[[:space:]]*//p' \
            | head -n 1
    )"

    if [[ -z "$private" || -z "$public" ]]; then
        die "无法识别当前内核输出的 Reality 密钥格式。"
        return 1
    fi

    jq -n \
        --arg uuid "$uuid" \
        --arg private "$private" \
        --arg sni "$sni" \
        --arg sid "$sid" \
        --argjson port "$port" \
        '{
            log: {
                level: "info"
            },
            inbounds: [
                {
                    type: "vless",
                    tag: "vless-reality-in",
                    listen: "::",
                    listen_port: $port,
                    users: [
                        {
                            uuid: $uuid,
                            flow: "xtls-rprx-vision"
                        }
                    ],
                    tls: {
                        enabled: true,
                        server_name: $sni,
                        reality: {
                            enabled: true,
                            handshake: {
                                server: $sni,
                                server_port: 443
                            },
                            private_key: $private,
                            short_id: [$sid]
                        }
                    }
                }
            ],
            outbounds: [
                {
                    type: "direct",
                    tag: "direct"
                }
            ]
        }' > "$CONFIG"

    chmod 600 "$CONFIG"

    # 先检查配置，再创建或启动服务。
    if ! "$BIN" check -c "$CONFIG"; then
        die "Sing-box 配置检查失败，服务不会启动。"
        return 1
    fi

    cat > "$UNIT" <<EOF
[Unit]
Description=xiazhetng8 Sing-box Node Manager
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$BIN run -c $CONFIG
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF

    node="vless://${uuid}@${ip}:${port}?encryption=none&security=reality&sni=${sni}&fp=chrome&pbk=${public}&sid=${sid}&type=tcp&flow=xtls-rprx-vision#xiazhetng8"

    printf '%s\n' "$node" > "$NODE"
    printf '%s\n' "$node" | base64 -w 0 > "$SUB"
    chmod 600 "$NODE" "$SUB" "$UNIT"

    systemctl daemon-reload

    if ! systemctl enable --now "$SERVICE"; then
        systemctl --no-pager -l status "$SERVICE" || true
        die "服务启动失败，请检查日志。"
        return 1
    fi

    sleep 2

    if ! systemctl is-active --quiet "$SERVICE"; then
        systemctl --no-pager -l status "$SERVICE" || true
        die "服务没有正常运行。"
        return 1
    fi

    # 如果 UFW 已启用，只添加本节点所需的 TCP 规则。
    # 不清空规则，也不禁用防火墙。
    if has ufw && ufw status 2>/dev/null | grep -q 'Status: active'; then
        ufw allow "${port}/tcp" || \
            yellow "自动添加 UFW 规则失败，请手动开放 TCP $port。"
    fi

    line
    green "节点部署完成。"
    yellow "公网地址：$ip"
    yellow "节点端口：$port/TCP"
    yellow "节点协议：VLESS + REALITY"
    line

    green "节点连接："
    printf '%s\n' "$node"

    line
    green "Base64 订阅内容："
    cat "$SUB"
    printf '\n'

    line
    yellow "节点文件：$NODE"
    yellow "订阅内容文件：$SUB"
    yellow "注意：当前输出的是 Base64 订阅内容，不是公网订阅 URL。"
    yellow "还需检查云厂商安全组是否放行 TCP $port。"
}

# -------------------- 一键安装 --------------------

install_all() {
    need_root || return 1
    detect_os || return 1

    # 已有本项目服务时不重新生成密钥或覆盖配置。
    if systemctl is-active --quiet "$SERVICE" 2>/dev/null; then
        yellow "本项目服务已在运行。"
        show_node
        return 0
    fi

    # 检查本项目配置，防止重复安装时覆盖旧节点。
    if [[ -e "$CONFIG" || -e "$UNIT" ]]; then
        yellow "发现本项目已有配置或服务文件。"
        yellow "为避免覆盖现有节点，请先检查服务状态或选择卸载。"
        return 1
    fi

    install_deps || return 1
    install_kernel || return 1
    create_node
}

# -------------------- 快捷入口 --------------------

install_shortcut() {
    need_root || return 1

    mkdir -p "$APPDIR"

    local source
    source="${BASH_SOURCE[0]}"

    # 优先复制当前实际脚本文件。
    # 如果通过 curl | bash 或 /dev/fd 执行，则从仓库下载。
    if [[ -f "$source" && "$source" != /dev/fd/* ]]; then
        install -m 0755 "$source" "$SCRIPT_FILE"
    else
        local tmp
        tmp="$(mktemp)"

        if ! curl -fLsS --retry 3 "$RAW_URL" -o "$tmp"; then
            rm -f "$tmp"
            die "无法下载脚本。请先将脚本提交到 GitHub 仓库。"
            return 1
        fi

        if ! bash -n "$tmp"; then
            rm -f "$tmp"
            die "下载的脚本语法检查失败。"
            return 1
        fi

        install -m 0755 "$tmp" "$SCRIPT_FILE"
        rm -f "$tmp"
    fi

    cat > "$SHORTCUT" <<'EOF'
#!/usr/bin/env bash
exec bash /usr/local/lib/xiazheteng-singbox/sing-box-manager.sh "$@"
EOF

    chmod 755 "$SHORTCUT"

    green "快捷入口已创建。"
    yellow "以后可以直接输入：x"
}

# -------------------- 卸载 --------------------

uninstall_all() {
    need_root || return 1

    yellow "此操作将删除本项目管理的服务、配置、节点文件和快捷入口。"
    yellow "不会主动清理其他项目的服务、配置或防火墙规则。"

    read -r -p "确定卸载？请输入 yes：" answer

    if [[ "$answer" != "yes" ]]; then
        yellow "已取消卸载。"
        return 0
    fi

    systemctl disable --now "$SERVICE" 2>/dev/null || true

    rm -f "$UNIT"
    rm -f "$SHORTCUT"

    systemctl daemon-reload

    rm -rf "$BASE"

    # 内核安装在独立目录，不删除系统共享的 /usr/local/bin/sing-box。
    rm -rf "$APPDIR"

    green "本项目的服务、配置及快捷入口已卸载。"
    yellow "如曾手动添加 UFW 或云安全组规则，请自行检查并清理。"
}

# -------------------- 服务管理 --------------------

service_status() {
    systemctl --no-pager -l status "$SERVICE" || true
}

service_restart() {
    if systemctl restart "$SERVICE"; then
        green "服务已重启。"
    else
        red "服务重启失败。"
        systemctl --no-pager -l status "$SERVICE" || true
    fi
}

service_logs() {
    journalctl -u "$SERVICE" -n 100 --no-pager || true
}

show_node() {
    if [[ -s "$NODE" ]]; then
        cat "$NODE"
    else
        yellow "未找到节点文件，请先执行一键安装。"
    fi
}

backup_config() {
    if [[ ! -s "$CONFIG" ]]; then
        yellow "配置文件不存在。"
        return 1
    fi

    local dst
    dst="$BASE/backup-$(date +%Y%m%d-%H%M%S).tar.gz"

    tar -czf "$dst" -C "$BASE" config.json node.txt subscribe.txt
    chmod 600 "$dst"

    green "配置备份完成：$dst"
}

port_check() {
    if [[ -s "$CONFIG" ]]; then
        jq -r '
            .inbounds[] |
            "\(.type) \(.listen):\(.listen_port)"
        ' "$CONFIG"
    else
        yellow "当前没有本项目配置。"
    fi

    line
    ss -lntup 2>/dev/null || true
}

# -------------------- 内核更新 --------------------

update_kernel() {
    need_root || return 1

    if [[ ! -x "$BIN" || ! -s "$CONFIG" ]]; then
        yellow "本项目的内核或配置不存在，请先安装。"
        return 1
    fi

    local backup
    backup="$BASE/config.json.backup.$(date +%Y%m%d%H%M%S)"

    cp -a "$CONFIG" "$backup"

    if ! install_kernel; then
        yellow "内核更新失败，原配置备份仍保留：$backup"
        return 1
    fi

    if ! "$BIN" check -c "$CONFIG"; then
        yellow "新内核无法通过配置检查。备份位置：$backup"
        return 1
    fi

    if systemctl restart "$SERVICE"; then
        green "内核更新后服务已重启。"
        yellow "配置备份：$backup"
    else
        red "服务重启失败，请检查日志。"
        yellow "配置备份：$backup"
        return 1
    fi
}

# -------------------- 更多功能 --------------------

bbr_setup() {
    need_root || return 1

    if [[ ! -r /proc/sys/net/ipv4/tcp_available_congestion_control ]]; then
        yellow "无法读取当前内核支持的拥塞控制算法。"
        return 1
    fi

    if ! grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control; then
        yellow "当前内核未报告 BBR 可用。请勿盲目更换生产内核。"
        return 1
    fi

    cat > /etc/sysctl.d/99-xiazheteng-bbr.conf <<'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF

    if sysctl --system >/dev/null; then
        green "已应用 BBR + FQ 设置。"
        sysctl net.ipv4.tcp_congestion_control
        sysctl net.core.default_qdisc
    else
        red "sysctl 应用失败，请检查系统日志。"
        return 1
    fi
}

certificate_info() {
    line
    yellow "当前基础节点使用 VLESS + REALITY。"
    yellow "该模式不需要本脚本申请的常规 TLS 证书。"
    yellow "本版本未实现 ACME 域名证书申请或证书自动续期。"
    line
}

connectivity_check() {
    local host
    local failed=0

    for host in github.com www.microsoft.com; do
        if curl -IsS --max-time 8 "https://${host}" >/dev/null 2>&1; then
            green "${host}：HTTPS 连接成功"
        else
            red "${host}：HTTPS 连接失败"
            failed=1
        fi
    done

    return "$failed"
}

update_script() {
    need_root || return 1

    local tmp
    tmp="$(mktemp)"

    if ! curl -fLsS --retry 3 "$RAW_URL" -o "$tmp"; then
        rm -f "$tmp"
        die "下载脚本失败。"
        return 1
    fi

    if ! bash -n "$tmp"; then
        rm -f "$tmp"
        die "新脚本语法检查失败，未执行更新。"
        return 1
    fi

    # 更新快捷入口使用的持久化副本。
    install -m 0755 "$tmp" "$SCRIPT_FILE"
    rm -f "$tmp"

    green "管理脚本已更新。"
    yellow "请退出菜单后重新运行 x。"
}

# -------------------- 子菜单 --------------------

kernel_menu() {
    while true; do
        clear 2>/dev/null || true

        line
        blue "内核相关设置"
        line

        cat <<'EOF'
3.  查看服务状态
4.  重启服务
5.  查看运行日志
6.  更新 Sing-box 内核
7.  查看节点连接
8.  备份配置
9.  检查监听端口
10. 返回主菜单
EOF

        read -r -p "请选择：" choice

        case "$choice" in
            3) service_status; pause ;;
            4) service_restart; pause ;;
            5) service_logs; pause ;;
            6) update_kernel; pause ;;
            7) show_node; pause ;;
            8) backup_config; pause ;;
            9) port_check; pause ;;
            10) return 0 ;;
            *) yellow "无效选项。"; pause ;;
        esac
    done
}

more_menu() {
    while true; do
        clear 2>/dev/null || true

        line
        blue "更多功能"
        line

        cat <<'EOF'
11. 尝试启用 BBR + FQ
12. 查看证书说明
13. 检查外部 HTTPS 连通性
14. 更新管理脚本
0.  返回主菜单
EOF

        read -r -p "请选择：" choice

        case "$choice" in
            11) bbr_setup; pause ;;
            12) certificate_info; pause ;;
            13) connectivity_check || true; pause ;;
            14) update_script; pause ;;
            0) return 0 ;;
            *) yellow "无效选项。"; pause ;;
        esac
    done
}

# -------------------- 主菜单 --------------------

main_menu() {
    while true; do
        clear 2>/dev/null || true

        line
        blue "          ${BRAND} | Sing-box 节点管理器"
        line

        cat <<'EOF'
1. 一键安装（安装内核、部署节点、输出连接及订阅内容）
2. 一键卸载
3-10. 内核相关设置
11-14. 更多功能
x. 创建快捷启动命令
q. 退出
EOF

        line
        read -r -p "请输入选项：" choice

        case "$choice" in
            1) install_all; pause ;;
            2) uninstall_all; pause ;;
            3|4|5|6|7|8|9|10) kernel_menu ;;
            11|12|13|14) more_menu ;;
            x|X) install_shortcut; pause ;;
            q|Q) exit 0 ;;
            *) yellow "无效选项。"; pause ;;
        esac
    done
}

main() {
    case "${1:-}" in
        --install)
            install_all
            ;;
        --uninstall)
            uninstall_all
            ;;
        --help|-h)
            printf '用法：bash sing-box-manager.sh [--install|--uninstall|--help]\n'
            ;;
        *)
            main_menu
            ;;
    esac
}

main "$@"
