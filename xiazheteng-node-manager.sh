
#!/usr/bin/env bash
# ============================================================
# 瞎折腾吧 | VPS 节点管理器
# GitHub:   https://github.com/xiazheteng8/xiazheteng-node-manager
# YouTube:  https://www.youtube.com/@xiazheteng8
# Telegram: https://t.me/xiazheteng8
#
# 功能：
# 1. VLESS-REALITY 一键部署
# 2. 可选域名 + HTTPS 订阅
# 3. 无域名模式（默认）
# 4. 自动选择空闲端口
# 5. 订阅聚合
# 6. SSH 输入 x / X 快捷启动
# 7. 管理本脚本独立创建的服务
#
# 注意：独立配置，不覆盖 Xray 原有全局配置。
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

mkdir -p "$CONFIG_DIR" "$DATA_DIR"

# -------------------- 基础工具 --------------------

info() { printf '\033[1;34m[信息]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[成功]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[提示]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[错误]\033[0m %s\n' "$*" >&2; }

pause() {
    echo
    read -r -p "按回车键继续..." _ || true
}

need_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        err "请使用 root 权限运行。"
        exit 1
    fi
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

install_packages() {
    export DEBIAN_FRONTEND=noninteractive

    if command_exists apt-get; then
        apt-get update
        apt-get install -y curl ca-certificates unzip openssl \
            python3 nginx certbot python3-certbot-nginx \
            iproute2 uuid-runtime
    else
        err "当前版本仅自动处理 Debian / Ubuntu 的 apt 包管理器。"
        return 1
    fi
}

random_port() {
    local port tries=0

    while (( tries < 200 )); do
        port="$(shuf -i 20000-60000 -n 1)"

        if ! ss -H -lntup 2>/dev/null |
            awk '{print $5}' |
            grep -Eq "[:.]${port}$"; then
            printf '%s\n' "$port"
            return 0
        fi

        ((tries+=1))
    done

    err "无法找到空闲端口。"
    return 1
}

get_public_ip() {
    local ip=""
    ip="$(curl -4 -fsS --max-time 8 https://api.ipify.org 2>/dev/null || true)"

    if [[ -z "$ip" ]]; then
        ip="$(curl -4 -fsS --max-time 8 https://ipv4.icanhazip.com 2>/dev/null | tr -d '[:space:]' || true)"
    fi

    if [[ -z "$ip" ]]; then
        err "无法自动获取公网 IPv4，请检查 VPS 网络。"
        return 1
    fi

    printf '%s\n' "$ip"
}

# -------------------- 快捷入口 --------------------

install_shortcut() {
    info "配置管理器快捷入口..."

    # 如果当前正在执行的就是本地文件，直接安装当前版本。
    if [[ -f "${BASH_SOURCE[0]}" && "${BASH_SOURCE[0]}" != /dev/fd/* ]]; then
        if [[ "$(readlink -f "${BASH_SOURCE[0]}")" != "$(readlink -m "$MANAGER_PATH")" ]]; then
            install -m 755 "${BASH_SOURCE[0]}" "$MANAGER_PATH"
        fi
    elif [[ ! -f "$MANAGER_PATH" ]]; then
        # 通过 curl | bash 或进程替换启动时，尝试从仓库下载持久版本。
        if ! curl -fLsS --retry 2 "$GITHUB_RAW" -o "$MANAGER_PATH"; then
            warn "无法从 GitHub 下载持久脚本。"
            warn "请先将完整脚本提交到仓库后，再运行安装入口。"
        else
            chmod 755 "$MANAGER_PATH"
        fi
    fi

    if [[ -f "$MANAGER_PATH" ]]; then
        cat > "$SHORTCUT_PATH" <<'SHORTCUT'
#!/usr/bin/env bash
exec bash /usr/local/bin/xiazheteng-node-manager.sh "$@"
SHORTCUT
        chmod 755 "$SHORTCUT_PATH"
        ok "快捷入口已配置：输入 x 即可启动。"
    fi
}

# -------------------- Xray 安装 --------------------

install_xray() {
    if [[ -x "$XRAY" ]]; then
        ok "检测到 Xray：$("$XRAY" version 2>/dev/null | head -n 1 || true)"
        return 0
    fi

    info "正在安装 Xray..."

    install_packages

    bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

    if [[ ! -x "$XRAY" ]]; then
        err "Xray 安装后未找到 $XRAY。"
        return 1
    fi

    ok "Xray 安装完成。"
}

# -------------------- REALITY 密钥解析 --------------------

reality_keys() {
    local output

    output="$("$XRAY" x25519 2>&1)" || {
        err "Xray 密钥生成命令执行失败："
        printf '%s\n' "$output" >&2
        return 1
    }

    # 兼容：
    # PrivateKey: ...
    # Password (PublicKey): ...
    # Hash32: ...
    #
    # 也兼容 Private key / Public key 等常见字段名称。
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

private_key = fields.get("privatekey", "")
public_key = (
    fields.get("passwordpublickey", "")
    or fields.get("publickey", "")
    or fields.get("password", "")
    or fields.get("public", "")
)

if not private_key or not public_key:
    print("[错误] 无法识别 Xray 密钥输出格式。", file=sys.stderr)
    print("识别到的字段：" + ", ".join(fields.keys()), file=sys.stderr)
    print("原始输出如下：", file=sys.stderr)
    print(text, file=sys.stderr)
    sys.exit(1)

if private_key == public_key:
    print("[错误] 私钥与公钥字段相同，拒绝继续。", file=sys.stderr)
    sys.exit(1)

print(private_key)
print(public_key)
' <<< "$output"
}

# -------------------- 节点链接 --------------------

make_reality_link() {
    local ip="$1"
    local port="$2"
    local uuid="$3"
    local public_key="$4"
    local sid="$5"
    local remark="$6"

    python3 - "$ip" "$port" "$uuid" "$public_key" "$sid" "$remark" <<'PY'
import sys
from urllib.parse import quote

ip, port, uid, pbk, sid, remark = sys.argv[1:]

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
    f"vless://{uid}@{ip}:{port}?{params}#{quote(remark, safe='')}"
)
PY
}

# -------------------- 域名 HTTPS 订阅 --------------------

configure_https_subscription() {
    local domain email token

    echo
    read -r -p "请输入已解析到本机的域名：" domain

    domain="${domain,,}"
    domain="${domain%.}"

    if [[ ! "$domain" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]] ||
       [[ "$domain" != *.* ]] ||
       [[ "$domain" == *..* ]]; then
        err "域名格式不正确。"
        return 1
    fi

    read -r -p "请输入用于证书申请的邮箱：" email

    if [[ ! "$email" =~ ^[^@]+@[^@]+\.[^@]+$ ]]; then
        err "邮箱格式不正确。"
        return 1
    fi

    install_packages
    mkdir -p "$SUB_DIR"

    # 为 Certbot 保留标准 HTTP Web 根目录。
    systemctl enable --now nginx

    info "正在为 ${domain} 申请 HTTPS 证书..."

    if ! certbot --nginx \
        -d "$domain" \
        --non-interactive \
        --agree-tos \
        --email "$email" \
        --redirect; then
        err "证书申请失败。请检查域名 DNS、80/443 端口和服务商安全组。"
        return 1
    fi

    token="$(openssl rand -hex 24)"
    printf '%s\n' "$token" > "$TOKEN_FILE"
    printf '%s\n' "$domain" > "$SETTINGS_FILE"

    mkdir -p "$SUB_DIR"
    chmod 755 "$NGINX_ROOT" "$SUB_DIR"

    ok "HTTPS 订阅域名配置完成。"
}

# -------------------- 订阅文件生成 --------------------

write_subscription() {
    local raw_file="$1"
    local domain token out_file

    if [[ ! -s "$raw_file" ]]; then
        err "没有可生成的节点链接。"
        return 1
    fi

    if [[ -s "$SETTINGS_FILE" && -s "$TOKEN_FILE" ]]; then
        domain="$(head -n 1 "$SETTINGS_FILE")"
        token="$(head -n 1 "$TOKEN_FILE")"
        out_file="${SUB_DIR}/${token}"

        mkdir -p "$SUB_DIR"
        base64 -w 0 "$raw_file" > "$out_file"
        chmod 644 "$out_file"

        echo
        ok "HTTPS 订阅已更新："
        printf 'https://%s/sub/%s\n' "$domain" "$token"
        return 0
    fi

    echo
    info "当前没有配置域名 HTTPS 订阅。"
    info "以下为可直接导入客户端的节点链接："
    cat "$raw_file"
}

# -------------------- VLESS-REALITY 部署 --------------------

deploy_reality() {
    local mode port ip uuid keys private_key public_key sid remark link
    local raw_file="${DATA_DIR}/nodes.txt"

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

    mkdir -p "$CONFIG_DIR" "$DATA_DIR"

    # 只写入本项目独立配置，不覆盖 /usr/local/etc/xray/config.json。
    cat > "$XRAY_CONFIG" <<JSON
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

    if ! "$XRAY" run -test -config "$XRAY_CONFIG"; then
        err "Xray 配置测试失败，服务未启动。"
        return 1
    fi

    cat > "$SERVICE_FILE" <<SERVICE
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

    systemctl daemon-reload
    systemctl enable --now "$SERVICE_NAME"

    if ! systemctl is-active --quiet "$SERVICE_NAME"; then
        err "节点服务启动失败。"
        journalctl -u "$SERVICE_NAME" -n 50 --no-pager || true
        return 1
    fi

    link="$(make_reality_link "$ip" "$port" "$uuid" "$public_key" "$sid" "$remark")"

    # 保留已登记节点并避免重复写入同一链接。
    touch "$NODES_FILE"
    if ! grep -Fxq "$link" "$NODES_FILE"; then
        printf '%s\n' "$link" >> "$NODES_FILE"
    fi

    # 生成客户端订阅内容。
    write_subscription "$NODES_FILE"

    echo
    ok "VLESS-REALITY 部署完成。"
    printf '服务器地址：%s\n' "$ip"
    printf '监听端口：%s\n' "$port"
    printf '客户端 UUID：%s\n' "$uuid"
    printf 'REALITY 公钥：%s\n' "$public_key"
    printf 'Short ID：%s\n' "$sid"
    echo
    warn "请在云服务商安全组中放行 TCP ${port}。"
    warn "本脚本不会自动修改所有云平台的外部安全组。"
}

# -------------------- 订阅聚合 --------------------

aggregate_subscription() {
    local tmp="${DATA_DIR}/subscription.raw"

    touch "$NODES_FILE"

    # 仅聚合本管理器登记的可识别分享链接。
    # 不把服务器配置 JSON 直接当作客户端分享链接。
    grep -E '^(vless|vmess|trojan|ss|hysteria2|tuic)://' \
        "$NODES_FILE" 2>/dev/null | awk '!seen[$0]++' > "$tmp" || true

    if [[ ! -s "$tmp" ]]; then
        warn "当前没有发现本管理器登记的节点链接。"
        return 0
    fi

    write_subscription "$tmp"
}

# -------------------- 服务管理 --------------------

service_status() {
    echo
    systemctl status "$SERVICE_NAME" --no-pager || true
    pause
}

restart_service() {
    if [[ ! -f "$SERVICE_FILE" ]]; then
        warn "本项目的节点服务尚未安装。"
        return 0
    fi

    systemctl restart "$SERVICE_NAME"
    systemctl status "$SERVICE_NAME" --no-pager || true
}

uninstall_manager() {
    echo
    warn "此操作只卸载本管理器创建的服务与配置。"
    warn "不会主动删除系统中的其他 Xray 配置或其他服务。"
    read -r -p "确认卸载本管理器节点服务及其配置？[y/N]：" answer

    case "${answer,,}" in
        y|yes)
            systemctl disable --now "$SERVICE_NAME" 2>/dev/null || true
            rm -f "$SERVICE_FILE"
            systemctl daemon-reload

            rm -rf "$BASE_DIR"

            # 不删除共享的 Nginx、Certbot 或系统 Xray 安装。
            warn "本项目服务及配置已删除。"
            warn "为避免影响其他程序，快捷入口和管理脚本未自动删除。"
            ;;
        *)
            info "已取消。"
            ;;
    esac
}

more_features() {
    while true; do
        echo
        echo "========== 更多功能 =========="
        echo "1. 查看本项目节点服务状态"
        echo "2. 重启本项目节点服务"
        echo "3. 查看本项目节点配置路径"
        echo "4. 查看订阅聚合结果"
        echo "0. 返回主菜单"
        read -r -p "请选择：" choice

        case "$choice" in
            1) service_status ;;
            2) restart_service; pause ;;
            3)
                echo "Xray 配置：$XRAY_CONFIG"
                echo "节点列表：$NODES_FILE"
                pause
                ;;
            4) aggregate_subscription; pause ;;
            0) return ;;
            *) warn "无效选项。" ;;
        esac
    done
}

# -------------------- 主菜单 --------------------

show_menu() {
    while true; do
        clear 2>/dev/null || true

        echo "=============================================="
        echo "       ${APP_TITLE}"
        echo "=============================================="
        echo "1. 一键部署 VLESS-REALITY"
        echo "2. 卸载本项目节点服务"
        echo "3. 系统与服务设置"
        echo "4. 更多功能"
        echo "5. 一键聚合订阅"
        echo "0. 退出"
        echo "----------------------------------------------"
        echo "快捷键：x / X 启动菜单，q / Q 退出"
        echo

        read -r -p "请选择：" choice || exit 0

        case "${choice,,}" in
            1)
                deploy_reality
                pause
                ;;
            2)
                uninstall_manager
                pause
                ;;
            3)
                echo
                echo "========== 系统与服务设置 =========="
                echo "1. 查看本项目服务状态"
                echo "2. 重启本项目服务"
                echo "0. 返回"
                read -r -p "请选择：" subchoice

                case "$subchoice" in
                    1) service_status ;;
                    2) restart_service; pause ;;
                    *) ;;
                esac
                ;;
            4)
                more_features
                ;;
            5)
                aggregate_subscription
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

# -------------------- 入口 --------------------

main() {
    need_root
    install_shortcut
    show_menu
}

main "$@"
