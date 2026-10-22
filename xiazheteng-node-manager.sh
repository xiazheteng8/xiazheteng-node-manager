
cat > /root/xiazheteng-node-manager.sh <<'SCRIPT_EOF'
#!/usr/bin/env bash
# ============================================================
# 瞎折腾吧 | X-UI / 3X-UI 节点管理器
# 单文件版本 | Ubuntu 22.04
# ============================================================

set -uo pipefail
umask 077

CONFIG_DIR="/etc/x-ui"
CONFIG_FILE="${CONFIG_DIR}/node-manager.env"
DB_FILE="/etc/x-ui/x-ui.db"
COOKIE_FILE="$(mktemp)"
BODY_FILE="$(mktemp)"
trap 'rm -f "$COOKIE_FILE" "$BODY_FILE"' EXIT

RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[36m'
RESET='\033[0m'

info() { echo -e "${BLUE}[信息]${RESET} $*"; }
ok()   { echo -e "${GREEN}[成功]${RESET} $*"; }
warn() { echo -e "${YELLOW}[警告]${RESET} $*"; }
err()  { echo -e "${RED}[错误]${RESET} $*" >&2; }

pause() {
    echo
    read -r -p "按回车键返回菜单..." _ || true
}

normalize_path() {
    local p="${1:-/}"

    # 合并任意连续斜杠，例如 /abc/// -> /abc/
    p="$(printf '%s' "$p" | sed -E 's#/+#/#g')"

    [[ -n "$p" ]] || p="/"
    [[ "$p" == /* ]] || p="/$p"

    # 根路径单独处理，其他路径统一保留一个末尾斜杠
    if [[ "$p" != "/" ]]; then
        p="${p%/}"
        p="${p}/"
    fi

    printf '%s' "$p"
}

need_root() {
    if [[ "$EUID" -ne 0 ]]; then
        err "请使用 root 运行。"
        exit 1
    fi
}

install_deps() {
    local missing=()
    local cmd

    for cmd in curl jq openssl sed awk; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done

    if ((${#missing[@]})); then
        info "安装必要依赖：${missing[*]}"
        export DEBIAN_FRONTEND=noninteractive
        apt-get update || return 1
        apt-get install -y curl jq openssl ca-certificates || return 1
    fi

    ok "依赖检查完成。"
}

load_config() {
    XUI_HOST="127.0.0.1"
    XUI_PANEL_PORT="22682"
    XUI_BASE_PATH="/"
    XUI_USERNAME=""
    XUI_PASSWORD=""

    if [[ -f "$CONFIG_FILE" ]]; then
        # 配置文件由本脚本生成，权限应限制为 root 可读写
        # shellcheck disable=SC1090
        source "$CONFIG_FILE"
    fi

    XUI_HOST="${XUI_HOST:-127.0.0.1}"
    XUI_PANEL_PORT="${XUI_PANEL_PORT:-22682}"
    XUI_BASE_PATH="$(normalize_path "${XUI_BASE_PATH:-/}")"
    XUI_USERNAME="${XUI_USERNAME:-}"
    XUI_PASSWORD="${XUI_PASSWORD:-}"

    if [[ ! "$XUI_PANEL_PORT" =~ ^[0-9]{1,5}$ ]] ||
       ((10#$XUI_PANEL_PORT < 1 || 10#$XUI_PANEL_PORT > 65535)); then
        XUI_PANEL_PORT="22682"
    fi

    rebuild_url
}

rebuild_url() {
    XUI_BASE_PATH="$(normalize_path "${XUI_BASE_PATH:-/}")"
    PANEL_ROOT="http://${XUI_HOST}:${XUI_PANEL_PORT}${XUI_BASE_PATH}"
}

save_config() {
    install -d -m 700 "$CONFIG_DIR"
    XUI_BASE_PATH="$(normalize_path "$XUI_BASE_PATH")"

    {
        printf 'XUI_HOST=%q\n' "$XUI_HOST"
        printf 'XUI_PANEL_PORT=%q\n' "$XUI_PANEL_PORT"
        printf 'XUI_BASE_PATH=%q\n' "$XUI_BASE_PATH"
        printf 'XUI_USERNAME=%q\n' "$XUI_USERNAME"
        printf 'XUI_PASSWORD=%q\n' "$XUI_PASSWORD"
    } > "$CONFIG_FILE"

    chmod 600 "$CONFIG_FILE"
    rebuild_url
    ok "配置已保存，路径已规范化：$XUI_BASE_PATH"
    ok "面板地址：$PANEL_ROOT"
}

configure_panel() {
    local value

    echo
    echo "===== 面板连接配置 ====="
    echo "当前面板地址：$PANEL_ROOT"

    read -r -p "面板主机/IP [${XUI_HOST}]: " value
    [[ -n "$value" ]] && XUI_HOST="$value"

    read -r -p "面板端口 [${XUI_PANEL_PORT}]: " value
    [[ -n "$value" ]] && XUI_PANEL_PORT="$value"

    if [[ ! "$XUI_PANEL_PORT" =~ ^[0-9]{1,5}$ ]] ||
       ((10#$XUI_PANEL_PORT < 1 || 10#$XUI_PANEL_PORT > 65535)); then
        err "端口无效。"
        return 1
    fi

    read -r -p "面板基础路径 [${XUI_BASE_PATH}]: " value
    [[ -n "$value" ]] && XUI_BASE_PATH="$value"
    XUI_BASE_PATH="$(normalize_path "$XUI_BASE_PATH")"

    read -r -p "面板用户名 [${XUI_USERNAME}]: " value
    [[ -n "$value" ]] && XUI_USERNAME="$value"

    read -r -s -p "面板密码（留空保持原密码）: " value
    echo
    [[ -n "$value" ]] && XUI_PASSWORD="$value"

    rebuild_url
    save_config
}

http_check() {
    local url="$1"
    curl -sS -o "$BODY_FILE" -w 'HTTP %{http_code}\n' \
        --connect-timeout 5 --max-time 15 "$url" || true
}

diagnostics() {
    rebuild_url

    echo
    echo "===== 配置检查 ====="
    echo "主机：$XUI_HOST"
    echo "端口：$XUI_PANEL_PORT"
    echo "基础路径：$XUI_BASE_PATH"
    echo "面板 URL：$PANEL_ROOT"
    echo "用户名：${XUI_USERNAME:-未设置}"
    [[ -n "$XUI_PASSWORD" ]] && echo "密码：已设置（隐藏）" || echo "密码：未设置"

    echo
    echo "===== 服务状态 ====="
    systemctl --no-pager --full status x-ui 2>&1 | head -n 18 || true

    echo
    echo "===== 数据库 ====="
    if [[ -f "$DB_FILE" ]]; then
        ls -lh "$DB_FILE"
    else
        warn "没有找到数据库文件：$DB_FILE"
    fi

    echo
    echo "===== 根路径 ====="
    http_check "http://${XUI_HOST}:${XUI_PANEL_PORT}/"

    echo
    echo "===== 面板基础路径 ====="
    http_check "$PANEL_ROOT"

    echo
    echo "===== CSRF 接口 ====="
    http_check "${PANEL_ROOT}csrf-token"
    jq . "$BODY_FILE" 2>/dev/null || head -c 500 "$BODY_FILE"
    echo
}

get_csrf() {
    local response

    response="$(curl -fsS --connect-timeout 5 --max-time 15 \
        -c "$COOKIE_FILE" -b "$COOKIE_FILE" \
        "${PANEL_ROOT}csrf-token" 2>/dev/null)" || return 1

    printf '%s' "$response" | jq -r '.obj // .token // empty' 2>/dev/null
}

api_login() {
    local csrf code

    rebuild_url

    if [[ -z "$XUI_USERNAME" || -z "$XUI_PASSWORD" ]]; then
        err "请先通过菜单 1 配置面板用户名和密码。"
        return 1
    fi

    : > "$COOKIE_FILE"

    csrf="$(get_csrf)" || {
        err "获取 CSRF Token 失败，请检查面板 URL 和网络。"
        return 1
    }

    if [[ -z "$csrf" ]]; then
        err "CSRF Token 为空。"
        return 1
    fi

    # 使用表单方式提交登录信息，并携带 CSRF Token 与 Cookie
    code="$(curl -sS -o "$BODY_FILE" -w '%{http_code}' \
        --connect-timeout 5 --max-time 20 \
        -c "$COOKIE_FILE" -b "$COOKIE_FILE" \
        -H "X-CSRF-Token: ${csrf}" \
        --data-urlencode "username=${XUI_USERNAME}" \
        --data-urlencode "password=${XUI_PASSWORD}" \
        "${PANEL_ROOT}login" 2>/dev/null)" || {
        err "面板登录请求失败。"
        return 1
    }

    if [[ "$code" != "200" ]] ||
       ! jq -e '.success == true' "$BODY_FILE" >/dev/null 2>&1; then
        err "登录未成功，HTTP 状态：$code"
        jq . "$BODY_FILE" 2>/dev/null || cat "$BODY_FILE"
        echo
        return 1
    fi

    ok "面板登录成功。"
}

api_request() {
    local method="$1"
    local endpoint="$2"
    shift 2

    local csrf code
    csrf="$(get_csrf 2>/dev/null || true)"

    code="$(curl -sS -o "$BODY_FILE" -w '%{http_code}' \
        --connect-timeout 5 --max-time 30 \
        -c "$COOKIE_FILE" -b "$COOKIE_FILE" \
        -H "X-CSRF-Token: ${csrf}" \
        "$@" \
        -X "$method" \
        "${PANEL_ROOT}${endpoint}" 2>/dev/null)" || {
        err "API 请求失败：$endpoint"
        return 1
    }

    if [[ "$code" != "200" ]] ||
       ! jq -e '.success == true' "$BODY_FILE" >/dev/null 2>&1; then
        err "API 请求失败，HTTP 状态：$code"
        jq . "$BODY_FILE" 2>/dev/null || cat "$BODY_FILE"
        echo
        return 1
    fi

    return 0
}

list_inbounds() {
    echo
    echo "===== 获取入站列表 ====="

    api_login || return 1
    api_request GET "panel/api/inbounds/list" || return 1

    jq -r '
      if (.obj | type) == "array" then
        if (.obj | length) == 0 then
          "当前没有入站。"
        else
          .obj[] |
          "ID: \(.id // "") | 备注: \(.remark // "") | 协议: \(.protocol // "") | 端口: \(.port // "") | 启用: \(.enable // false)"
        end
      else
        "返回数据结构不符合预期：\(.obj|type)"
      end
    ' "$BODY_FILE" || {
        err "解析入站列表失败。"
        return 1
    }
}

find_xray() {
    local p
    for p in \
        "$(command -v xray 2>/dev/null || true)" \
        "/usr/local/x-ui/bin/xray-linux-amd64" \
        "/usr/local/x-ui/bin/xray" \
        "/usr/bin/xray"; do
        if [[ -n "$p" && -x "$p" ]]; then
            printf '%s' "$p"
            return 0
        fi
    done
    return 1
}

create_reality() {
    local xray remark port target sni uuid output private_key public_key short_id
    local settings stream sniffing code

    echo
    echo "===== 创建 VLESS + REALITY 入站 ====="
    api_login || return 1

    xray="$(find_xray)" || {
        err "找不到 Xray 可执行文件。"
        return 1
    }

    read -r -p "入站备注 [瞎折腾吧-REALITY]: " remark
    remark="${remark:-瞎折腾吧-REALITY}"

    read -r -p "监听端口 [随机生成]: " port
    port="${port:-$((20000 + RANDOM % 30001))}"

    if [[ ! "$port" =~ ^[0-9]{1,5}$ ]] ||
       ((10#$port < 1 || 10#$port > 65535)); then
        err "端口无效。"
        return 1
    fi

    read -r -p "REALITY 目标域名 [www.microsoft.com]: " target
    target="${target:-www.microsoft.com}"
    target="${target#http://}"
    target="${target#https://}"
    target="${target%%/*}"
    target="${target%%:*}"

    read -r -p "ServerName [${target}]: " sni
    sni="${sni:-$target}"

    if [[ ! "$target" =~ ^[A-Za-z0-9.-]+$ ||
          ! "$sni" =~ ^[A-Za-z0-9.-]+$ ]]; then
        err "域名格式无效。"
        return 1
    fi

    uuid="$(cat /proc/sys/kernel/random/uuid)"
    output="$("$xray" x25519 2>&1)" || {
        err "Xray 密钥生成失败："
        echo "$output"
        return 1
    }

    private_key="$(printf '%s\n' "$output" |
        sed -nE 's/^[[:space:]]*(PrivateKey|Private key):[[:space:]]*([^[:space:]]+).*/\2/p' |
        head -n 1)"

    public_key="$(printf '%s\n' "$output" |
        sed -nE 's/^[[:space:]]*(Password|PublicKey|Public key):[[:space:]]*([^[:space:]]+).*/\2/p' |
        head -n 1)"

    if [[ -z "$private_key" || -z "$public_key" ]]; then
        err "无法识别当前 Xray 的密钥输出格式，未创建入站。"
        echo "$output"
        return 1
    fi

    short_id="$(openssl rand -hex 8)" || return 1

    settings="$(jq -cn --arg id "$uuid" '{
      clients:[{
        id:$id,
        flow:"xtls-rprx-vision",
        email:"",
        limitIp:0,
        totalGB:0,
        expiryTime:0,
        enable:true
      }],
      decryption:"none",
      fallbacks:[]
    }')"

    stream="$(jq -cn \
        --arg dest "${target}:443" \
        --arg sni "$sni" \
        --arg key "$private_key" \
        --arg sid "$short_id" '{
          network:"tcp",
          security:"reality",
          realitySettings:{
            show:false,
            xver:0,
            dest:$dest,
            serverNames:[$sni],
            privateKey:$key,
            shortIds:[$sid]
          },
          tcpSettings:{header:{type:"none"}}
        }')"

    sniffing='{"enabled":true,"destOverride":["http","tls","quic"],"metadataOnly":false,"routeOnly":false}'

    # 3x-ui 常见 API 使用表单字段，settings 等字段以 JSON 字符串传递
    code="$(curl -sS -o "$BODY_FILE" -w '%{http_code}' \
        --connect-timeout 5 --max-time 30 \
        -c "$COOKIE_FILE" -b "$COOKIE_FILE" \
        -H 'Accept: application/json' \
        -H 'Content-Type: application/x-www-form-urlencoded' \
        --data-urlencode "remark=${remark}" \
        --data-urlencode "enable=true" \
        --data-urlencode "listen=" \
        --data-urlencode "port=${port}" \
        --data-urlencode "protocol=vless" \
        --data-urlencode "settings=${settings}" \
        --data-urlencode "streamSettings=${stream}" \
        --data-urlencode "sniffing=${sniffing}" \
        "${PANEL_ROOT}panel/api/inbounds/add" 2>/dev/null)" || {
        err "创建入站请求失败。"
        return 1
    }

    if [[ "$code" != "200" ]] ||
       ! jq -e '.success == true' "$BODY_FILE" >/dev/null 2>&1; then
        err "面板拒绝创建入站，HTTP $code。"
        jq . "$BODY_FILE" 2>/dev/null || cat "$BODY_FILE"
        echo
        return 1
    fi

    ok "面板已接受创建请求。"
    echo
    echo "===== 连接参数 ====="
    echo "协议：VLESS"
    echo "地址：填写 VPS 公网 IP 或域名"
    echo "端口：$port"
    echo "UUID：$uuid"
    echo "传输：TCP"
    echo "安全：REALITY"
    echo "Flow：xtls-rprx-vision"
    echo "SNI：$sni"
    echo "Public Key：$public_key"
    echo "Short ID：$short_id"
    echo "Fingerprint：chrome"
    echo
    warn "请到面板确认入站确实存在，并确认防火墙已允许该端口。"
}

service_menu() {
    local choice

    echo
    echo "===== X-UI 服务管理 ====="
    echo "1. 查看服务状态"
    echo "2. 查看最近 100 行日志"
    echo "3. 重启 X-UI"
    echo "4. 返回"
    read -r -p "请选择 [1-4]: " choice || return

    case "$choice" in
        1) systemctl --no-pager --full status x-ui || true ;;
        2) journalctl -u x-ui -n 100 --no-pager || true ;;
        3)
            if systemctl restart x-ui; then
                ok "已发送重启命令。"
                systemctl --no-pager --full status x-ui | head -n 18 || true
            else
                err "重启失败，请检查日志。"
            fi
            ;;
        4) return ;;
        *) warn "无效选项。" ;;
    esac
}

main_menu() {
    local choice

    while true; do
        rebuild_url
        echo
        echo "============================================================"
        echo "  瞎折腾吧 | X-UI 节点管理器"
        echo "============================================================"
        echo "面板：$PANEL_ROOT"
        echo "------------------------------------------------------------"
        echo "  1. 配置面板连接信息"
        echo "  2. 检查配置、HTTP 与 CSRF"
        echo "  3. 登录面板并列出入站"
        echo "  4. 创建 VLESS + REALITY 入站"
        echo "  5. 服务状态、日志与重启"
        echo "  6. 保存并规范化当前配置"
        echo "  0. 退出"
        echo "============================================================"

        read -r -p "请选择 [0-6]: " choice || break

        case "$choice" in
            1) configure_panel; pause ;;
            2) diagnostics; pause ;;
            3) list_inbounds; pause ;;
            4) create_reality; pause ;;
            5) service_menu; pause ;;
            6) save_config; pause ;;
            0) echo "已退出。"; break ;;
            *) warn "无效选项。"; pause ;;
        esac
    done
}

main() {
    need_root
    install_deps || {
        err "依赖安装失败，无法启动管理器。"
        exit 1
    }

    load_config

    if [[ ! -f "$CONFIG_FILE" ]]; then
        warn "首次运行，请先选择菜单 1 配置面板连接信息。"
    fi

    main_menu
}

main "$@"
SCRIPT_EOF

chmod 700 /root/xiazheteng-node-manager.sh &&
bash -n /root/xiazheteng-node-manager.sh &&
exec bash /root/xiazheteng-node-manager.sh
