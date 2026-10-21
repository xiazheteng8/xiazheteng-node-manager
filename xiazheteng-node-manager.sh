
#!/usr/bin/env bash
# ============================================================
# 瞎折腾吧 | VPS 节点管理器 IPv4-only
# GitHub:   https://github.com/xiazheteng8/xiazheteng-node-manager
# YouTube:  https://www.youtube.com/@xiazheteng8
# Telegram: https://t.me/xiazheteng8
#
# 独立实现：VLESS + REALITY + Vision
# 默认不使用域名，不覆盖现有 Xray 配置。
# ============================================================

set -Eeuo pipefail
umask 077

APP="xiazheteng-node-manager"
BASE="/usr/local/etc/xiazheteng-node-manager"
XRAY="/usr/local/bin/xray-xiazheteng"
CONFIG="$BASE/config.json"
INFO="$BASE/node.info"
SUB="$BASE/subscription.txt"
SERVICE="xiazheteng-xray"
UNIT="/etc/systemd/system/${SERVICE}.service"
LOG="/var/log/${APP}.log"

mkdir -p "$BASE"
touch "$LOG"

info() { echo -e "\033[36m[信息]\033[0m $*"; }
ok()   { echo -e "\033[32m[成功]\033[0m $*"; }
warn() { echo -e "\033[33m[警告]\033[0m $*"; }
err()  { echo -e "\033[31m[错误]\033[0m $*" >&2; }

pause() {
    echo
    read -r -p "按回车键继续..." _
}

need_root() {
    if [[ $EUID -ne 0 ]]; then
        err "请使用 root 运行：sudo bash $0"
        exit 1
    fi
}

has_cmd() { command -v "$1" >/dev/null 2>&1; }

install_packages() {
    local packages=("$@")
    if has_cmd apt-get; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update
        apt-get install -y "${packages[@]}"
    elif has_cmd dnf; then
        dnf install -y "${packages[@]}"
    elif has_cmd yum; then
        yum install -y "${packages[@]}"
    else
        err "不支持的包管理器，请使用 Debian/Ubuntu 或 RHEL 系发行版。"
        return 1
    fi
}

detect_arch() {
    case "$(uname -m)" in
        x86_64|amd64) echo "64" ;;
        aarch64|arm64) echo "arm64-v8a" ;;
        *)
            err "暂不支持 CPU 架构：$(uname -m)"
            return 1
            ;;
    esac
}

get_ipv4() {
    local ip=""
    ip="$(curl -4 -fsS --connect-timeout 5 \
        https://api.ipify.org 2>/dev/null || true)"
    if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        printf '%s' "$ip"
    else
        return 1
    fi
}

port_free() {
    local port="$1"
    if has_cmd ss; then
        ! ss -H -lnt "sport = :$port" 2>/dev/null | grep -q .
    else
        ! (echo >/dev/tcp/127.0.0.1/"$port") 2>/dev/null
    fi
}

choose_port() {
    local p
    if port_free 443; then
        echo 443
        return 0
    fi

    warn "443 端口已被占用，不会停止或覆盖现有服务。"
    for p in $(shuf -i 20000-50000 -n 100); do
        if port_free "$p"; then
            echo "$p"
            return 0
        fi
    done

    err "没有找到可用端口。"
    return 1
}

install_xray() {
    local arch tag url tmp
    arch="$(detect_arch)" || return 1

    if [[ -x "$XRAY" ]]; then
        ok "检测到本管理器安装的 Xray：$("$XRAY" version 2>/dev/null | head -n 1)"
        return 0
    fi

    info "正在获取 Xray 最新正式版信息……"
    tag="$(curl -fsSL --connect-timeout 10 \
        https://api.github.com/repos/XTLS/Xray-core/releases/latest |
        sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -n 1)"

    if [[ -z "$tag" ]]; then
        err "无法获取 Xray 版本信息，请检查 VPS 网络和 GitHub 访问。"
        return 1
    fi

    url="https://github.com/XTLS/Xray-core/releases/download/${tag}/Xray-linux-${arch}.zip"
    tmp="$(mktemp -d)"
    trap 'rm -rf "${tmp:-}"' RETURN

    install_packages curl unzip ca-certificates jq openssl

    info "下载 Xray：$tag"
    if ! curl -fL --retry 2 "$url" -o "$tmp/xray.zip"; then
        err "Xray 下载失败：$url"
        return 1
    fi

    unzip -oq "$tmp/xray.zip" -d "$tmp/unpacked"
    if [[ ! -f "$tmp/unpacked/xray" ]]; then
        err "下载包中没有找到 Xray 主程序。"
        return 1
    fi

    install -m 0755 "$tmp/unpacked/xray" "$XRAY"
    "$XRAY" version >/dev/null
    ok "Xray 安装完成。"
}

generate_keys() {
    local output private public shortid
    output="$("$XRAY" x25519 2>&1)" || {
        err "Xray 密钥生成失败：$output"
        return 1
    }

    # 兼容常见 Xray 输出字段名。
    private="$(printf '%s\n' "$output" |
        sed -nE 's/^[[:space:]]*(PrivateKey|Private key):[[:space:]]*//p' |
        head -n 1)"
    public="$(printf '%s\n' "$output" |
        sed -nE 's/^[[:space:]]*(Password|PublicKey|Public key):[[:space:]]*//p' |
        head -n 1)"

    if [[ -z "$private" || -z "$public" ]]; then
        err "无法识别 Xray 密钥输出格式。"
        printf '%s\n' "$output"
        return 1
    fi

    shortid="$(openssl rand -hex 8)"
    printf '%s\n%s\n%s\n' "$private" "$public" "$shortid"
}

install_unit() {
    if [[ -e "$UNIT" ]]; then
        warn "管理器服务文件已存在，将先备份。"
        cp -a "$UNIT" "$UNIT.bak.$(date +%Y%m%d%H%M%S)"
    fi

    cat > "$UNIT" <<EOF
[Unit]
Description=Xiazheteng Managed Xray Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=$XRAY run -config $CONFIG
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "$SERVICE" >/dev/null
}

show_node() {
    if [[ ! -s "$INFO" ]]; then
        warn "尚未生成节点。"
        return 1
    fi
    cat "$INFO"
}

create_node() {
    local ip port domain uuid keys private public shortid link answer
    need_root

    if [[ -s "$CONFIG" || -s "$INFO" ]]; then
        warn "检测到本管理器已有节点配置。"
        read -r -p "重新生成会替换本管理器的配置，是否继续？[y/N]：" answer
        [[ "$answer" =~ ^[Yy]$ ]] || return 0

        cp -a "$CONFIG" "$CONFIG.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
        cp -a "$INFO" "$INFO.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
    fi

    echo
    info "开始一键生成 VLESS + REALITY + Vision 节点"
    info "本流程不需要域名和 TLS 证书。"
    echo

    if ! has_cmd curl || ! has_cmd systemctl || ! has_cmd jq; then
        info "正在准备系统依赖……"
        install_packages curl ca-certificates unzip jq openssl
    fi

    install_xray || return 1

    ip="$(get_ipv4)" || {
        err "无法获取公网 IPv4，请确认 VPS 已分配公网 IPv4 并可访问外网。"
        return 1
    }
    ok "公网 IPv4：$ip"

    port="$(choose_port)" || return 1
    info "监听端口：$port"

    domain="www.microsoft.com"
    echo "REALITY 目标域名默认为：$domain"
    read -r -p "是否修改目标域名？[y/N]：" answer
    if [[ "$answer" =~ ^[Yy]$ ]]; then
        read -r -p "请输入支持 TLS 的目标域名（不要带端口）：" domain
        if [[ ! "$domain" =~ ^[A-Za-z0-9.-]+$ ]]; then
            err "域名格式无效。"
            return 1
        fi
    fi

    uuid="$("$XRAY" uuid)" || {
        err "UUID 生成失败。"
        return 1
    }

    keys="$(generate_keys)" || return 1
    private="$(printf '%s\n' "$keys" | sed -n '1p')"
    public="$(printf '%s\n' "$keys" | sed -n '2p')"
    shortid="$(printf '%s\n' "$keys" | sed -n '3p')"

    cat > "$CONFIG" <<EOF
{
  "log": {
    "loglevel": "warning",
    "access": "$BASE/access.log",
    "error": "$BASE/error.log"
  },
  "inbounds": [
    {
      "tag": "vless-reality",
      "listen": "0.0.0.0",
      "port": $port,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$uuid",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "$domain:443",
          "xver": 0,
          "serverNames": [
            "$domain"
          ],
          "privateKey": "$private",
          "shortIds": [
            "$shortid"
          ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"]
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
  ],
  "routing": {
    "rules": [
      {
        "type": "field",
        "ip": ["geoip:private"],
        "outboundTag": "block"
      }
    ]
  }
}
EOF

    chmod 600 "$CONFIG"

    if ! "$XRAY" run -test -config "$CONFIG"; then
        err "Xray 配置校验失败，保留配置供检查，不会报告部署成功。"
        return 1
    fi
    ok "Xray 配置语法校验通过。"

    install_unit

    if ! systemctl restart "$SERVICE"; then
        err "服务启动失败。最近日志："
        journalctl -u "$SERVICE" -n 40 --no-pager || true
        return 1
    fi

    sleep 2
    if ! systemctl is-active --quiet "$SERVICE"; then
        err "服务未能保持运行。"
        journalctl -u "$SERVICE" -n 40 --no-pager || true
        return 1
    fi

    link="vless://${uuid}@${ip}:${port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${domain}&fp=chrome&pbk=${public}&sid=${shortid}&type=tcp#XiaZheTeng-REALITY"

    {
        echo "节点名称：XiaZheTeng-REALITY"
        echo "服务器地址：$ip"
        echo "监听端口：$port"
        echo "协议：VLESS + REALITY + Vision"
        echo "目标域名：$domain"
        echo "UUID：$uuid"
        echo "公钥：$public"
        echo "Short ID：$shortid"
        echo "节点链接："
        echo "$link"
    } > "$INFO"

    printf '%s\n' "$link" > "$SUB"
    chmod 600 "$INFO" "$SUB"

    ok "节点服务已启动。"
    echo
    cat "$INFO"
    echo
    warn "请确认 VPS 云防火墙和系统防火墙允许 TCP $port。"
    warn "服务运行正常不代表公网端口一定可达；请从外部网络实测。"
}

manage_nodes() {
    need_root
    echo
    echo "===== 节点管理 ====="
    echo "1. 查看节点参数与链接"
    echo "2. 查看服务状态"
    echo "3. 重启本管理器节点服务"
    echo "4. 查看最近服务日志"
    echo "0. 返回"
    read -r -p "请输入选项：" choice

    case "$choice" in
        1) show_node || true ;;
        2) systemctl status "$SERVICE" --no-pager || true ;;
        3)
            if [[ -s "$CONFIG" ]]; then
                systemctl restart "$SERVICE" &&
                    ok "重启命令已执行。" ||
                    err "重启失败，请检查日志。"
            else
                warn "尚未生成节点。"
            fi
            ;;
        4) journalctl -u "$SERVICE" -n 80 --no-pager || true ;;
        0) return ;;
        *) warn "无效选项。" ;;
    esac
}

generate_subscription() {
    need_root
    if [[ ! -s "$SUB" ]]; then
        warn "尚无已部署的节点，无法生成订阅。"
        return 1
    fi

    install_packages coreutils
    local encoded
    encoded="$(base64 -w 0 "$SUB" 2>/dev/null ||
        base64 "$SUB" | tr -d '\r\n')"

    printf '%s\n' "$encoded" > "$BASE/subscription.base64"
    chmod 600 "$BASE/subscription.base64"

    ok "本地订阅内容已生成：$BASE/subscription.base64"
    echo "这是 Base64 编码的节点分享内容，不是公网 HTTPS 订阅 URL。"
    echo "如需 HTTPS 订阅，需要另行配置安全的 Web 服务与访问凭据。"
    echo
    read -r -p "是否显示 Base64 订阅内容？[y/N]：" answer
    if [[ "${answer:-N}" =~ ^[Yy]$ ]]; then
        cat "$BASE/subscription.base64"
        echo
    fi
}

network_check() {
    echo
    echo "===== IPv4 与节点网络检测 ====="

    if has_cmd curl; then
        echo -n "公网 IPv4："
        get_ipv4 || echo "获取失败"
    else
        echo "curl 未安装，无法检测公网 IPv4。"
    fi

    if has_cmd ip; then
        echo
        echo "===== 本机 IPv4 地址 ====="
        ip -4 addr show scope global || true
        echo
        echo "===== IPv4 默认路由 ====="
        ip -4 route show default || true
    fi

    if has_cmd ss; then
        echo
        echo "===== TCP 监听端口 ====="
        ss -lntp || true
    fi

    echo
    if systemctl is-active --quiet "$SERVICE"; then
        ok "$SERVICE 服务运行中。"
    else
        warn "$SERVICE 服务未运行或尚未安装。"
    fi

    echo
    echo "注意：本机监听状态不能代替外部端口连通性测试。"
}

maintenance() {
    need_root
    echo
    echo "===== 系统维护 ====="
    echo "1. 检查 Xray 配置"
    echo "2. 查看服务日志"
    echo "3. 备份本管理器配置"
    echo "0. 返回"
    read -r -p "请输入选项：" choice

    case "$choice" in
        1)
            if [[ -x "$XRAY" && -s "$CONFIG" ]]; then
                "$XRAY" run -test -config "$CONFIG"
            else
                warn "尚无可检查的配置。"
            fi
            ;;
        2) journalctl -u "$SERVICE" -n 100 --no-pager || true ;;
        3)
            local dest
            dest="/root/${APP}-backup-$(date +%Y%m%d-%H%M%S).tar.gz"
            tar -czf "$dest" -C "$(dirname "$BASE")" "$(basename "$BASE")"
            chmod 600 "$dest"
            ok "备份已保存：$dest"
            ;;
        0) return ;;
        *) warn "无效选项。" ;;
    esac
}

install_shortcut() {
    need_root
    local target="/usr/local/bin/x"
    local source
    source="$(readlink -f "$0")"

    if [[ "$source" != "$target" ]]; then
        cat > "$target" <<EOF
#!/usr/bin/env bash
exec bash "$source" "\$@"
EOF
        chmod 755 "$target"
    fi
    ok "快捷入口已设置。SSH 中输入 x 即可打开菜单。"
}

main_menu() {
    need_root
    while true; do
        clear 2>/dev/null || true
        echo "================================================"
        echo "       瞎折腾吧 | VPS 节点管理器"
        echo "       IPv4 优先 · 交互式部署"
        echo "================================================"
        echo " 1. 一键生成节点"
        echo " 2. 管理已生成的节点"
        echo " 3. 生成聚合订阅（本地文件）"
        echo " 4. 检测节点与网络"
        echo " 5. 系统设置与维护"
        echo " 0. 退出"
        echo "------------------------------------------------"
        read -r -p "请输入选项 [0-5]：" choice

        case "$choice" in
            1) create_node || true; pause ;;
            2) manage_nodes; pause ;;
            3) generate_subscription || true; pause ;;
            4) network_check; pause ;;
            5) maintenance; pause ;;
            0) exit 0 ;;
            x|X) install_shortcut; pause ;;
            *) warn "无效选项，请重新输入。"; pause ;;
        esac
    done
}

main_menu "$@"
