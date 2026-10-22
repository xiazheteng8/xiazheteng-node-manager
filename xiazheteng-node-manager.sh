
cat > /root/xiazheteng-node-manager.sh <<'SCRIPT_EOF'
#!/usr/bin/env bash
# ============================================================
# 瞎折腾吧 | X-UI / 3X-UI 节点管理器
# Ubuntu 22.04 | 单文件 Bash
# ============================================================

set -uo pipefail
umask 077

APP_NAME="瞎折腾吧 | X-UI 节点管理器"
CONFIG_DIR="/etc/x-ui"
CONFIG_FILE="${CONFIG_DIR}/node-manager.env"
DB_FILE="/etc/x-ui/x-ui.db"
COOKIE_FILE="/tmp/xiazheteng-xui-cookie.$$"
HTTP_BODY="/tmp/xiazheteng-xui-body.$$"

trap 'rm -f "$COOKIE_FILE" "$HTTP_BODY"' EXIT

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
    read -r -p "按回车键返回菜单..." _
}

need_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        err "请使用 root 运行此脚本。"
        exit 1
    fi
}

install_deps() {
    local missing=()
    local cmd

    for cmd in curl jq openssl sed grep awk; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done

    if ((${#missing[@]})); then
        info "正在安装依赖：${missing[*]}"
        export DEBIAN_FRONTEND=noninteractive
        apt-get update || {
            err "apt-get update 失败。"
            return 1
        }
        apt-get install -y curl jq openssl ca-certificates || {
            err "依赖安装失败。"
            return 1
        }
    fi

    ok "依赖检查完成。"
}

normalize_path() {
    local p="${1:-/}"

    [[ -z "$p" ]] && p="/"
    [[ "$p" == /* ]] || p="/$p"

    while [[ "$p" == *//* ]]; do
        p="${p//\/\//\/}"
    done

    if [[ "$p" != "/" ]]; then
        p="${p%/}/"
    fi

    printf '%s' "$p"
}

load_config() {
    XUI_HOST="${XUI_HOST:-127.0.0.1}"
    XUI_PANEL_PORT="${XUI_PANEL_PORT:-22682}"
    XUI_BASE_PATH="${XUI_BASE_PATH:-/}"
    XUI_USERNAME="${XUI_USERNAME:-}"
    XUI_PASSWORD="${XUI_PASSWORD:-}"

    if [[ -f "$CONFIG_FILE" ]]; then
        # 配置文件由本脚本生成，权限应限制为 root 可读写。
        # shellcheck disable=SC1090
        source "$CONFIG_FILE"
    fi

    XUI_HOST="${XUI_HOST:-127.0.0.1}"
    XUI_PANEL_PORT="${XUI_PANEL_PORT:-22682}"
    XUI_BASE_PATH="$(normalize_path "${XUI_BASE_PATH:-/}")"
    XUI_USERNAME="${XUI_USERNAME:-}"
    XUI_PASSWORD="${XUI_PASSWORD:-}"

    PANEL_ROOT="http://${XUI_HOST}:${XUI_PANEL_PORT}${XUI_BASE_PATH}"
}

save_config() {
    install -d -m 700 "$CONFIG_DIR"

    cat > "$CONFIG_FILE" <<EOF
XUI_HOST=$(printf '%q' "$XUI_HOST")
XUI_PANEL_PORT=$(printf '%q' "$XUI_PANEL_PORT")
XUI_BASE_PATH=$(printf '%q' "$XUI_BASE_PATH")
XUI_USERNAME=$(printf '%q' "$XUI_USERNAME")
XUI_PASSWORD=$(printf '%q' "$XUI_PASSWORD")
EOF

    chmod 600 "$CONFIG_FILE"
    ok "配置已保存：$CONFIG_FILE"
}

configure_panel() {
    echo
    echo "===== 配置面板连接信息 ====="
    echo "当前地址：${PANEL_ROOT}"

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

    read -r -s -p "面板密码（留空保持不变）: " value
    echo
    [[ -n "$value" ]] && XUI_PASSWORD="$value"

    PANEL_ROOT="http://${XUI_HOST}:${XUI_PANEL_PORT}${XUI_BASE_PATH}"
    save_config
}

check_config() {
    echo
    echo "===== 面板连接配置 ====="
    printf '主机：%s\n' "$XUI_HOST"
    printf '端口：%s\n' "$XUI_PANEL_PORT"
    printf '基础路径：%s\n' "$XUI_BASE_PATH"
    printf '用户名：%s\n' "${XUI_USERNAME:-未设置}"
    printf '密码：%s\n' "$([[ -n "$XUI_PASSWORD" ]] && echo '已设置（隐藏）' || echo '未设置')"
    printf '面板 URL：%s\n' "$PANEL_ROOT"

    echo
    echo "===== 服务状态 ====="
    systemctl --no-pager --full status x-ui 2>&1 | head -n 18 || true

    echo
    echo "===== 数据库文件 ====="
    if [[ -f "$DB_FILE" ]]; then
        ls -lh "$DB_FILE"
    else
        warn "未找到 $DB_FILE"
    fi

    echo
    echo "===== 根路径 HTTP 状态 ====="
    curl -sS -o /dev/null -w 'HTTP %{http_code}\n' \
        --connect-timeout 5 --max-time 10 \
        "http://${XUI_HOST}:${XUI_PANEL_PORT}/" || true

    echo
    echo "===== 面板基础路径 HTTP 状态 ====="
    curl -sS -o /dev/null -w 'HTTP %{http_code}\n' \
        --connect-timeout 5 --max-time 10 \
        "$PANEL_ROOT" || true

    echo
    echo "===== CSRF 接口 ====="
    local code
    code="$(curl -sS -o "$HTTP_BODY" -w '%{http_code}' \
        --connect-timeout 5 --max-time 10 \
        "${PANEL_ROOT}csrf-token" 2>/dev/null || true)"

    echo "HTTP ${code:-连接失败}"
    if [[ -s "$HTTP_BODY" ]]; then
        jq . "$HTTP_BODY" 2>/dev/null || head -c 500 "$HTTP_BODY"
        echo
    fi
}

get_csrf() {
    local response
    response="$(curl -fsS --connect-timeout 5 --max-time 15 \
        -c "$COOKIE_FILE" -b "$COOKIE_FILE" \
        "${PANEL_ROOT}csrf-token" 2>/dev/null)" || return 1

    printf '%s' "$response" | jq -r '.obj // .token // empty' 2>/dev/null
}

api_login() {
    if [[ -z "$XUI_USERNAME" || -z "$XUI_PASSWORD" ]]; then
        err "请先配置面板用户名和密码。"
        return 1
    fi

    PANEL_ROOT="http://${XUI_HOST}:${XUI_PANEL_PORT}${XUI_BASE_PATH}"
    : > "$COOKIE_FILE"

    local csrf login_code
    csrf="$(get_csrf)" || {
        err "无法获取 CSRF Token，请检查面板地址、路径及网络。"
        return 1
    }

    if [[ -z "$csrf" ]]; then
        err "CSRF Token 为空。"
        return 1
    fi

    login_code="$(curl -sS -o "$HTTP_BODY" -w '%{http_code}' \
        --connect-timeout 5 --max-time 20 \
        -c "$COOKIE_FILE" -b "$COOKIE_FILE" \
        -H 'Content-Type: application/json' \
        -H "X-CSRF-Token: ${csrf}" \
        -X POST \
        --data "$(jq -cn --arg u "$XUI_USERNAME" --arg p "$XUI_PASSWORD" \
            '{username:$u,password:$p}')" \
        "${PANEL_ROOT}login" 2>/dev/null)" || {
        err "登录请求失败。"
        return 1
    }

    if [[ "$login_code" != "200" ]]; then
        err "登录 HTTP 状态：$login_code"
        cat "$HTTP_BODY"
        echo
        return 1
    fi

    if ! jq -e '.success == true' "$HTTP_BODY" >/dev/null 2>&1; then
        err "面板未确认登录成功，响应如下："
        jq . "$HTTP_BODY" 2>/dev/null || cat "$HTTP_BODY"
        echo
        return 1
    fi

    ok "面板登录成功。"
}

api_get() {
    local endpoint="$1"
    local csrf code

    csrf="$(get_csrf 2>/dev/null || true)"

    code="$(curl -sS -o "$HTTP_BODY" -w '%{http_code}' \
        --connect-timeout 5 --max-time 25 \
        -c "$COOKIE_FILE" -b "$COOKIE_FILE" \
        -H "X-CSRF-Token: ${csrf}" \
        "${PANEL_ROOT}${endpoint}" 2>/dev/null)" || {
        err "API 请求失败：$endpoint"
        return 1
    }

    if [[ "$code" != "200" ]]; then
        err "API HTTP 状态：$code"
        cat "$HTTP_BODY"
        echo
        return 1
    fi

    if ! jq -e '.success == true' "$HTTP_BODY" >/dev/null 2>&1; then
        err "API 返回失败或登录状态失效：$endpoint"
        jq . "$HTTP_BODY" 2>/dev/null || cat "$HTTP_BODY"
        echo
        return 1
    fi

    return 0
}

list_inbounds() {
    echo
    echo "===== 登录面板并读取入站 ====="

    api_login || return 1
    api_get "panel/api/inbounds/list" || return 1

    jq -r '
      if (.obj | type) == "array" then
        .obj[] |
        [
          ("ID: " + ((.id // "")|tostring)),
          ("备注: " + (.remark // "")),
          ("协议: " + (.protocol // "")),
          ("端口: " + ((.port // "")|tostring)),
          ("启用: " + ((.enable // false)|tostring)),
          ("流量: " + ((.totalGB // 0)|tostring) + " GB")
        ] | join(" | ")
      else
        "面板返回的数据结构与预期不同：\(.obj|type)"
      end
    ' "$HTTP_BODY" || {
        err "无法解析入站列表。"
        return 1
    }
}

find_xray() {
    local candidate
    for candidate in \
        "$(command -v xray 2>/dev/null || true)" \
        "/usr/local/x-ui/bin/xray-linux-amd64" \
        "/usr/local/x-ui/bin/xray" \
        "/usr/bin/xray"; do
        if [[ -n "$candidate" && -x "$candidate" ]]; then
            printf '%s' "$candidate"
            return 0
        fi
    done
    return 1
}

create_reality() {
    echo
    echo "===== 创建 VLESS + REALITY 入站 ====="

    api_login || return 1

    local xray
    xray="$(find_xray)" || {
        err "找不到 Xray 可执行文件，无法生成 REALITY 密钥。"
        return 1
    }

    local remark port target server_name uuid key_output private_key public_key short_id
    read -r -p "入站备注 [瞎折腾吧-REALITY]: " remark
    remark="${remark:-瞎折腾吧-REALITY}"

    read -r -p "监听端口 [随机 20000-50000]: " port
    if [[ -z "$port" ]]; then
        port=$((20000 + RANDOM % 30001))
    fi

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

    read -r -p "ServerName [${target}]: " server_name
    server_name="${server_name:-$target}"

    if [[ ! "$target" =~ ^[A-Za-z0-9.-]+$ ||
          ! "$server_name" =~ ^[A-Za-z0-9.-]+$ ]]; then
        err "域名格式无效。"
        return 1
    fi

    if ! command -v uuidgen >/dev/null 2>&1; then
        apt-get install -y uuid-runtime >/dev/null 2>&1 || true
    fi

    if command -v uuidgen >/dev/null 2>&1; then
        uuid="$(uuidgen)"
    else
        uuid="$(cat /proc/sys/kernel/random/uuid)"
    fi

    key_output="$("$xray" x25519 2>&1)" || {
        err "Xray 生成 REALITY 密钥失败："
        echo "$key_output"
        return 1
    }

    private_key="$(printf '%s\n' "$key_output" |
        sed -nE 's/^[[:space:]]*(PrivateKey|Private key):[[:space:]]*([^[:space:]]+).*/\2/p' |
        head -n 1)"

    # 不同 Xray 版本曾使用 Password 表示公钥。
    public_key="$(printf '%s\n' "$key_output" |
        sed -nE 's/^[[:space:]]*(Password|PublicKey|Public key):[[:space:]]*([^[:space:]]+).*/\2/p' |
        head -n 1)"

    if [[ -z "$private_key" || -z "$public_key" ]]; then
        err "无法识别 Xray 密钥输出格式，未创建入站。"
        echo "$key_output"
        return 1
    fi

    short_id="$(openssl rand -hex 8)" || return 1

    local settings stream sniffing payload
    settings="$(jq -cn --arg id "$uuid" '{
      clients:[{id:$id,flow:"xtls-rprx-vision",email:"",limitIp:0,totalGB:0,expiryTime:0,enable:true}],
      decryption:"none",
      fallbacks:[]
    }')"

    stream="$(jq -cn \
        --arg dest "${target}:443" \
        --arg server "$server_name" \
        --arg private "$private_key" \
        --arg sid "$short_id" '{
          network:"tcp",
          security:"reality",
          externalProxy:[],
          realitySettings:{
            show:false,
            xver:0,
            dest:$dest,
            serverNames:[$server],
            privateKey:$private,
            minClientVer:"",
            maxClientVer:"",
            maxTimeDiff:0,
            shortIds:[$sid]
          },
          tcpSettings:{acceptProxyProtocol:false,header:{type:"none"}}
        }')"

    sniffing='{"enabled":true,"destOverride":["http","tls","quic"],"metadataOnly":false,"routeOnly":false}'

    payload="$(jq -cn \
        --arg remark "$remark" \
        --argjson port "$port" \
        --arg settings "$settings" \
        --arg stream "$stream" \
        --arg sniff "$sniffing" '{
          remark:$remark,
          enable:true,
          listen:"",
          port:$port,
          protocol:"vless",
          settings:$settings,
          streamSettings:$stream,
          tag:"",
          sniffing:$sniff
        }')"

    api_get "panel/api/inbounds/list" || return 1

    local code
    code="$(curl -sS -o "$HTTP_BODY" -w '%{http_code}' \
        --connect-timeout 5 --max-time 30 \
        -c "$COOKIE_FILE" -b "$COOKIE_FILE" \
        -H 'Content-Type: application/json' \
        -H 'Accept: application/json' \
        -X POST \
        --data "$payload" \
        "${PANEL_ROOT}panel/api/inbounds/add" 2>/dev/null)" || {
        err "创建入站请求失败。"
        return 1
    }

    if [[ "$code" != "200" ]] ||
       ! jq -e '.success == true' "$HTTP_BODY" >/dev/null 2>&1; then
        err "面板拒绝创建入站，HTTP $code。"
        jq . "$HTTP_BODY" 2>/dev/null || cat "$HTTP_BODY"
        echo
        return 1
    fi

    ok "面板已接受创建请求。"
    echo
    echo "===== 本次生成的连接参数 ====="
    echo "协议：VLESS"
    echo "地址：请填写本机公网 IPv4 或已解析域名"
    echo "端口：$port"
    echo "UUID：$uuid"
    echo "传输：TCP"
    echo "安全：REALITY"
    echo "Flow：xtls-rprx-vision"
    echo "SNI：$server_name"
    echo "Public Key：$public_key"
    echo "Short ID：$short_id"
    echo "Fingerprint：chrome"
    echo
    warn "请确认面板中该入站已出现，并确认端口可从公网访问。"
    warn "若面板版本不接受该 API 数据结构，请检查面板返回内容及版本对应的 API 格式。"
}

service_menu() {
    echo
    echo "===== X-UI 服务管理 ====="
    echo "1. 查看服务状态"
    echo "2. 查看最近 100 行日志"
    echo "3. 重启 X-UI"
    echo "4. 返回"
    read -r -p "请选择 [1-4]: " choice

    case "$choice" in
        1)
            systemctl --no-pager --full status x-ui || true
            ;;
        2)
            journalctl -u x-ui -n 100 --no-pager || true
            ;;
        3)
            if systemctl restart x-ui; then
                ok "重启命令已执行。"
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
    while true; do
        clear 2>/dev/null || true
        echo "============================================================"
        echo "  $APP_NAME"
        echo "============================================================"
        echo "面板：${PANEL_ROOT}"
        echo "------------------------------------------------------------"
        echo "  1. 配置面板连接信息"
        echo "  2. 检查配置、HTTP 与 CSRF"
        echo "  3. 登录面板并列出入站"
        echo "  4. 创建 VLESS + REALITY 入站"
        echo "  5. 服务状态、日志与重启"
        echo "  6. 保存当前配置"
        echo "  0. 退出"
        echo "============================================================"

        read -r -p "请选择 [0-6]: " choice || break

        case "$choice" in
            1) configure_panel; pause ;;
            2) check_config; pause ;;
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
    install_deps || exit 1
    load_config

    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo
        warn "首次运行：请先进入菜单 1 配置面板连接信息。"
    fi

    main_menu
}

main "$@"
SCRIPT_EOF

chmod 700 /root/xiazheteng-node-manager.sh
bash -n /root/xiazheteng-node-manager.sh || exit 1
exec bash /root/xiazheteng-node-manager.sh
