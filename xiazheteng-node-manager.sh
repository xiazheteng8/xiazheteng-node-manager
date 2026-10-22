cat > /root/xiazheteng-node-manager.sh <<'SCRIPT_EOF'
#!/usr/bin/env bash
# ============================================================
# 瞎折腾吧 | VPS 多节点管理器
# 单文件安装器：3x-ui + VLESS REALITY + Shadowsocks + 订阅
# 目标系统：Ubuntu / Debian
# ============================================================

set -Eeuo pipefail
umask 077

APP_NAME="瞎折腾吧 | VPS 节点管理器"
INSTALL_DIR="/opt/xiazheteng-node-manager"
CONFIG_FILE="/etc/x-ui/node-manager.env"
SUB_DIR="/var/lib/xiazheteng-node-manager/sub"
SUB_PORT="18888"
SERVICE_NAME="xiazheteng-subscription"
COOKIE_FILE="/tmp/xiazheteng-xui-cookie.$$"

mkdir -p "$INSTALL_DIR" "$SUB_DIR"
chmod 700 "$INSTALL_DIR" "$SUB_DIR"
trap 'rm -f "$COOKIE_FILE"' EXIT

RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[34m'
RESET='\033[0m'

info() { echo -e "${BLUE}[信息]${RESET} $*"; }
ok()   { echo -e "${GREEN}[成功]${RESET} $*"; }
warn() { echo -e "${YELLOW}[警告]${RESET} $*"; }
err()  { echo -e "${RED}[错误]${RESET} $*" >&2; }

pause() {
    read -r -p "按 Enter 返回菜单..." _ || true
}

need_root() {
    if [[ $EUID -ne 0 ]]; then
        err "请使用 root 运行：sudo bash $0"
        exit 1
    fi
}

need_commands() {
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y curl ca-certificates jq openssl uuid-runtime \
        python3 iproute2 lsof
}

random_hex() {
    openssl rand -hex "${1:-8}"
}

valid_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 ))
}

port_free() {
    ! ss -H -lntup 2>/dev/null | grep -Eq "[:.]$1([[:space:]]|$)"
}

choose_port() {
    local p
    for _ in $(seq 1 100); do
        p=$((20000 + RANDOM % 40000))
        if port_free "$p"; then
            echo "$p"
            return 0
        fi
    done
    return 1
}

get_public_ipv4() {
    local ip=""
    ip="$(curl -4 -fsS --max-time 8 https://api.ipify.org 2>/dev/null || true)"
    if [[ -z "$ip" ]]; then
        ip="$(curl -4 -fsS --max-time 8 https://ifconfig.me/ip 2>/dev/null || true)"
    fi
    echo "$ip"
}

save_config() {
    install -d -m 700 /etc/x-ui
    cat > "$CONFIG_FILE" <<EOF
XUI_USERNAME=$(printf '%q' "$XUI_USERNAME")
XUI_PASSWORD=$(printf '%q' "$XUI_PASSWORD")
XUI_PANEL_PORT=$(printf '%q' "$XUI_PANEL_PORT")
XUI_BASE_PATH=$(printf '%q' "$XUI_BASE_PATH")
PUBLIC_HOST=$(printf '%q' "$PUBLIC_HOST")
SUB_PORT=$(printf '%q' "$SUB_PORT")
SUB_TOKEN=$(printf '%q' "$SUB_TOKEN")
EOF
    chmod 600 "$CONFIG_FILE"
}

load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        # shellcheck disable=SC1090
        source "$CONFIG_FILE"
    else
        XUI_USERNAME=""
        XUI_PASSWORD=""
        XUI_PANEL_PORT="22682"
        XUI_BASE_PATH="/$(random_hex 12)/"
        PUBLIC_HOST=""
        SUB_PORT="18888"
        SUB_TOKEN="$(random_hex 24)"
    fi
}

normalise_path() {
    local p="$1"
    [[ "$p" == /* ]] || p="/$p"
    [[ "$p" == */ ]] || p="$p/"
    echo "$p"
}

setup_config() {
    load_config

    echo
    echo "===== 首次初始化 / 修改配置 ====="

    read -r -p "3x-ui 管理用户名 [${XUI_USERNAME:-xiazheteng8}]: " v
    XUI_USERNAME="${v:-${XUI_USERNAME:-xiazheteng8}}"

    read -r -s -p "设置 3x-ui 管理密码（输入不显示）: " v
    echo
    if [[ -n "$v" ]]; then
        XUI_PASSWORD="$v"
    elif [[ -z "${XUI_PASSWORD:-}" ]]; then
        err "密码不能为空。"
        return 1
    fi

    read -r -p "面板端口 [${XUI_PANEL_PORT:-22682}]: " v
    XUI_PANEL_PORT="${v:-${XUI_PANEL_PORT:-22682}}"
    if ! valid_port "$XUI_PANEL_PORT"; then
        err "端口无效。"
        return 1
    fi

    read -r -p "面板安全路径 [${XUI_BASE_PATH:-自动生成}]: " v
    XUI_BASE_PATH="$(normalise_path "${v:-${XUI_BASE_PATH:-/$(random_hex 12)/}}")"

    read -r -p "节点连接使用的公网 IPv4 或域名 [自动检测]: " v
    PUBLIC_HOST="${v:-$(get_public_ipv4)}"
    if [[ -z "$PUBLIC_HOST" ]]; then
        read -r -p "未检测到公网地址，请手动输入服务器公网 IP/域名: " PUBLIC_HOST
    fi

    SUB_PORT="${SUB_PORT:-18888}"
    SUB_TOKEN="${SUB_TOKEN:-$(random_hex 24)}"

    save_config
    ok "配置已保存：$CONFIG_FILE"
}

install_3xui() {
    if command -v x-ui >/dev/null 2>&1; then
        ok "检测到已安装 3x-ui，跳过安装。"
    else
        echo
        warn "即将执行 3x-ui 官方安装程序。"
        read -r -p "确认继续安装？[y/N]: " ans
        [[ "$ans" =~ ^[Yy]$ ]] || return 1

        bash <(curl -fsSL --retry 3 \
          https://raw.githubusercontent.com/MHSanaei/3x-ui/master/install.sh)
    fi

    if ! command -v x-ui >/dev/null 2>&1; then
        err "未检测到 x-ui 命令。请检查安装过程是否完成。"
        return 1
    fi

    info "尝试使用 x-ui 命令行设置面板凭据、端口和安全路径..."
    if x-ui setting \
        -username "$XUI_USERNAME" \
        -password "$XUI_PASSWORD" \
        -port "$XUI_PANEL_PORT" \
        -webBasePath "$XUI_BASE_PATH"; then
        ok "已提交面板设置。"
    else
        warn "当前版本不支持此命令参数，或设置命令执行失败。"
        warn "请使用 x-ui 菜单设置面板凭据，然后重新运行本脚本。"
        return 1
    fi

    systemctl restart x-ui 2>/dev/null || service x-ui restart 2>/dev/null || true
    sleep 3
    ok "3x-ui 安装/设置流程结束。"
}

panel_root() {
    local path
    path="$(normalise_path "$XUI_BASE_PATH")"
    echo "http://127.0.0.1:${XUI_PANEL_PORT}${path}"
}

csrf_token() {
    local root="$1" response
    response="$(curl -fsS --max-time 10 \
        -c "$COOKIE_FILE" \
        "${root}csrf-token" 2>/dev/null)" || {
        err "获取 CSRF Token 失败，请检查面板端口、路径和服务状态。"
        return 1
    }

    echo "$response" | jq -er '
      if .success == true and (.obj | type == "string")
      then .obj else error("CSRF Token 响应异常") end
    '
}

api_login() {
    load_config
    local root token payload response

    root="$(panel_root)"
    rm -f "$COOKIE_FILE"

    info "获取 CSRF Token..."
    token="$(csrf_token "$root")" || return 1

    payload="$(jq -n \
        --arg u "$XUI_USERNAME" \
        --arg p "$XUI_PASSWORD" \
        '{username:$u,password:$p}')"

    info "登录 3x-ui..."
    response="$(curl -sS --max-time 15 \
        -b "$COOKIE_FILE" -c "$COOKIE_FILE" \
        -H 'Content-Type: application/json' \
        -H "X-CSRF-Token: $token" \
        -X POST "${root}login" \
        --data "$payload")" || {
            err "无法连接面板登录接口。"
            return 1
        }

    if ! echo "$response" | jq -e '.success == true' >/dev/null 2>&1; then
        err "面板登录失败："
        echo "$response" | jq . 2>/dev/null || echo "$response"
        warn "请确认用户名、密码、2FA 状态，以及当前版本的登录接口。"
        return 1
    fi

    ok "面板登录成功。"
}

api_post() {
    local endpoint="$1" payload="$2"
    local root token response

    root="$(panel_root)"
    token="$(csrf_token "$root")" || return 1

    response="$(curl -sS --max-time 20 \
        -b "$COOKIE_FILE" -c "$COOKIE_FILE" \
        -H 'Content-Type: application/json' \
        -H "X-CSRF-Token: $token" \
        -X POST "${root}panel/api/${endpoint}" \
        --data "$payload")" || {
            err "API 请求失败：$endpoint"
            return 1
        }

    if ! echo "$response" | jq -e '.success == true' >/dev/null 2>&1; then
        err "3x-ui API 返回失败：$endpoint"
        echo "$response" | jq . 2>/dev/null || echo "$response"
        return 1
    fi

    echo "$response"
}

api_get() {
    local endpoint="$1"
    local root
    root="$(panel_root)"

    curl -fsS --max-time 20 \
        -b "$COOKIE_FILE" \
        "${root}panel/api/${endpoint}"
}

generate_reality_keys() {
    local output private public

    if ! command -v xray >/dev/null 2>&1; then
        err "没有找到 xray 命令，无法生成 REALITY 密钥。"
        return 1
    fi

    output="$(xray x25519 2>&1)" || {
        err "xray x25519 执行失败：$output"
        return 1
    }

    private="$(printf '%s\n' "$output" |
        sed -nE 's/^[[:space:]]*PrivateKey:[[:space:]]*([^[:space:]]+).*/\1/p' |
        head -n1)"

    # Xray 新旧版本对公钥字段的命名可能不同。
    public="$(printf '%s\n' "$output" |
        sed -nE 's/^[[:space:]]*(Password|PublicKey):[[:space:]]*([^[:space:]]+).*/\2/p' |
        head -n1)"

    if [[ -z "$private" || -z "$public" ]]; then
        err "无法识别 xray x25519 的密钥输出格式。"
        echo "$output"
        return 1
    fi

    printf '%s\n%s\n' "$private" "$public"
}

add_reality_inbound() {
    local uuid email port keys private public shortid payload
    local remark="XT-Reality"

    uuid="$(uuidgen | tr '[:upper:]' '[:lower:]')"
    email="xt-reality-$(random_hex 3)"
    port="$(choose_port)" || {
        err "找不到可用监听端口。"
        return 1
    }

    mapfile -t keys < <(generate_reality_keys) || return 1
    private="${keys[0]}"
    public="${keys[1]}"
    shortid="$(openssl rand -hex 8)"

    payload="$(jq -n \
      --arg remark "$remark" \
      --arg uuid "$uuid" \
      --arg email "$email" \
      --argjson port "$port" \
      --arg private "$private" \
      --arg shortid "$shortid" \
      '{
        enable:true,
        remark:$remark,
        listen:"0.0.0.0",
        port:$port,
        protocol:"vless",
        expiryTime:0,
        total:0,
        settings:{
          clients:[{
            id:$uuid,
            email:$email,
            enable:true,
            flow:"xtls-rprx-vision",
            limitIp:0,
            totalGB:0,
            expiryTime:0
          }],
          decryption:"none",
          fallbacks:[]
        },
        streamSettings:{
          network:"tcp",
          security:"reality",
          realitySettings:{
            show:false,
            dest:"www.microsoft.com:443",
            xver:0,
            serverNames:["www.microsoft.com"],
            privateKey:$private,
            shortIds:[$shortid]
          }
        },
        sniffing:{
          enabled:true,
          destOverride:["http","tls","quic"]
        }
      }')"

    info "创建 VLESS + REALITY 入站，端口 $port..."
    api_post "inbounds/add" "$payload" >/dev/null || return 1

    printf '%s\n' \
      "vless://${uuid}@${PUBLIC_HOST}:${port}?type=tcp&security=reality&pbk=${public}&fp=chrome&sni=www.microsoft.com&sid=${shortid}&spx=%2F&flow=xtls-rprx-vision#XT-Reality" \
      >> "$SUB_DIR/nodes.txt"

    ok "VLESS + REALITY 入站已创建。"
    echo "端口：$port"
    echo "UUID：$uuid"
}

add_shadowsocks_inbound() {
    local password port method payload remark
    method="aes-128-gcm"
    password="$(openssl rand -base64 24 | tr -d '\n')"
    port="$(choose_port)" || {
        err "找不到可用监听端口。"
        return 1
    }
    remark="XT-Shadowsocks"

    payload="$(jq -n \
      --arg remark "$remark" \
      --arg password "$password" \
      --arg method "$method" \
      --argjson port "$port" \
      '{
        enable:true,
        remark:$remark,
        listen:"0.0.0.0",
        port:$port,
        protocol:"shadowsocks",
        expiryTime:0,
        total:0,
        settings:{
          method:$method,
          password:$password,
          network:"tcp,udp",
          ivCheck:false
        },
        streamSettings:{network:"tcp"},
        sniffing:{
          enabled:true,
          destOverride:["http","tls","quic"]
        }
      }')"

    info "创建 Shadowsocks 入站，端口 $port..."
    api_post "inbounds/add" "$payload" >/dev/null || return 1

    local encoded
    encoded="$(printf '%s' "${method}:${password}" | base64 -w0)"
    printf 'ss://%s@%s:%s#XT-Shadowsocks\n' \
        "$encoded" "$PUBLIC_HOST" "$port" >> "$SUB_DIR/nodes.txt"

    ok "Shadowsocks 入站已创建。"
    echo "端口：$port"
    echo "加密方式：$method"
}

install_subscription_service() {
    if ! port_free "$SUB_PORT"; then
        warn "订阅端口 $SUB_PORT 已被占用，暂不安装订阅 HTTP 服务。"
        warn "请更换 SUB_PORT 后重新运行。"
        return 1
    fi

    cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=Xiazheteng Node Subscription Server
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=${SUB_DIR}
ExecStart=/usr/bin/python3 -m http.server ${SUB_PORT} --bind 0.0.0.0 --directory ${SUB_DIR}
Restart=always
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
ReadWritePaths=${SUB_DIR}

[Install]
WantedBy=multi-user.target
EOF

    # 使用随机令牌作为订阅文件名，避免直接暴露固定文件路径。
    if [[ ! -f "$SUB_DIR/$SUB_TOKEN" ]]; then
        touch "$SUB_DIR/$SUB_TOKEN"
    fi

    chmod 600 "$SUB_DIR/$SUB_TOKEN"
    systemctl daemon-reload
    systemctl enable --now "$SERVICE_NAME"
    ok "订阅 HTTP 服务已启动。"
}

publish_subscription() {
    local tmp="$SUB_DIR/.subscription.tmp"

    if [[ ! -s "$SUB_DIR/nodes.txt" ]]; then
        err "当前没有节点链接。请先创建节点。"
        return 1
    fi

    # 订阅正文采用标准 Base64 编码。
    base64 -w0 "$SUB_DIR/nodes.txt" > "$tmp"
    mv "$tmp" "$SUB_DIR/$SUB_TOKEN"
    chmod 600 "$SUB_DIR/$SUB_TOKEN"

    echo
    echo "===== 多节点订阅 ====="
    echo "订阅地址："
    echo "http://${PUBLIC_HOST}:${SUB_PORT}/${SUB_TOKEN}"
    echo
    echo "节点明文链接："
    cat "$SUB_DIR/nodes.txt"
    echo
    warn "当前订阅服务使用 HTTP，不提供传输加密。不要在不可信网络中公开分享订阅地址。"
    warn "生产环境建议通过已有 HTTPS 域名和反向代理提供订阅，并限制订阅文件访问。"
}

deploy_nodes() {
    load_config

    if [[ -z "${XUI_USERNAME:-}" || -z "${XUI_PASSWORD:-}" ]]; then
        err "尚未完成初始化，请先选择 1。"
        return 1
    fi

    api_login || return 1

    touch "$SUB_DIR/nodes.txt"
    chmod 600 "$SUB_DIR/nodes.txt"

    echo
    echo "选择部署内容："
    echo "1. VLESS + REALITY"
    echo "2. Shadowsocks"
    echo "3. 两种都部署"
    read -r -p "请选择 [1-3]: " choice

    case "$choice" in
        1)
            add_reality_inbound || return 1
            ;;
        2)
            add_shadowsocks_inbound || return 1
            ;;
        3)
            add_reality_inbound || return 1
            add_shadowsocks_inbound || return 1
            ;;
        *)
            err "无效选项。"
            return 1
            ;;
    esac

    install_subscription_service || return 1
    publish_subscription
}

show_status() {
    echo
    echo "===== 服务状态 ====="
    systemctl --no-pager --full status x-ui 2>/dev/null || true
    echo
    systemctl --no-pager --full status "$SERVICE_NAME" 2>/dev/null || true
    echo
    echo "===== 监听端口 ====="
    ss -lntup 2>/dev/null | grep -E "x-ui|:${XUI_PANEL_PORT:-22682}|:${SUB_PORT:-18888}" || true
    echo
    echo "===== 已保存节点 ====="
    if [[ -s "$SUB_DIR/nodes.txt" ]]; then
        cat "$SUB_DIR/nodes.txt"
    else
        echo "尚无节点链接。"
    fi
}

show_logs() {
    echo "===== x-ui 最近日志 ====="
    journalctl -u x-ui -n 80 --no-pager 2>/dev/null || true
    echo
    echo "===== 订阅服务最近日志 ====="
    journalctl -u "$SERVICE_NAME" -n 50 --no-pager 2>/dev/null || true
}

restart_services() {
    systemctl restart x-ui 2>/dev/null || true
    systemctl restart "$SERVICE_NAME" 2>/dev/null || true
    ok "已发送重启命令。"
}

main_menu() {
    need_root
    need_commands
    load_config

    while true; do
        clear 2>/dev/null || true
        echo "============================================================"
        echo "  $APP_NAME"
        echo "============================================================"
        echo "面板端口：${XUI_PANEL_PORT:-未配置}"
        echo "面板路径：${XUI_BASE_PATH:-未配置}"
        echo "公网地址：${PUBLIC_HOST:-未配置}"
        echo "1. 首次初始化 / 修改面板账号与连接配置"
        echo "2. 安装或配置 3x-ui"
        echo "3. 自动部署节点并生成多节点订阅"
        echo "4. 查看订阅地址与节点链接"
        echo "5. 服务状态与监听端口"
        echo "6. 查看日志"
        echo "7. 重启服务"
        echo "0. 退出"
        echo "============================================================"

        read -r -p "请选择 [0-7]: " choice || exit 0

        case "$choice" in
            1)
                setup_config
                pause
                ;;
            2)
                load_config
                if [[ -z "${XUI_USERNAME:-}" || -z "${XUI_PASSWORD:-}" ]]; then
                    setup_config || { pause; continue; }
                fi
                install_3xui
                pause
                ;;
            3)
                deploy_nodes
                pause
                ;;
            4)
                load_config
                publish_subscription || true
                pause
                ;;
            5)
                show_status
                pause
                ;;
            6)
                show_logs
                pause
                ;;
            7)
                restart_services
                pause
                ;;
            0)
                exit 0
                ;;
            *)
                warn "请输入 0-7。"
                sleep 1
                ;;
        esac
    done
}

main_menu "$@"
SCRIPT_EOF

chmod 700 /root/xiazheteng-node-manager.sh
bash -n /root/xiazheteng-node-manager.sh &&
echo "语法检查通过，开始运行：" &&
bash /root/xiazheteng-node-manager.sh
