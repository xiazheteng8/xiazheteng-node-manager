
cat > /root/xiazheteng-node-manager.sh <<'SCRIPT_EOF'
#!/usr/bin/env bash
# ============================================================
# 瞎折腾吧 | X-UI 节点管理器
# 单文件版本：面板配置、CSRF 登录、入站列表、VLESS REALITY
# ============================================================

set -o pipefail
umask 077

SCRIPT_PATH="/root/xiazheteng-node-manager.sh"
CONFIG_FILE="/etc/x-ui/node-manager.env"
COOKIE_FILE="/tmp/xui-manager-cookies-$$.txt"
BODY_FILE="/tmp/xui-manager-body-$$.json"
CSRF_FILE="/tmp/xui-manager-csrf-$$.json"

mkdir -p /etc/x-ui
touch "$CONFIG_FILE"
chmod 600 "$CONFIG_FILE"

cleanup() {
    rm -f "$COOKIE_FILE" "$BODY_FILE" "$CSRF_FILE"
}
trap cleanup EXIT

# ---------- 基础工具 ----------

info() { printf '\033[36m[信息]\033[0m %s\n' "$*"; }
ok()   { printf '\033[32m[成功]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[警告]\033[0m %s\n' "$*"; }
err()  { printf '\033[31m[错误]\033[0m %s\n' "$*" >&2; }

pause() {
    echo
    read -r -p "按 Enter 返回菜单..." _
}

need_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        err "请使用 root 用户运行。"
        exit 1
    fi
}

normalize_path() {
    local p="${1:-/}"
    p="$(printf '%s' "$p" | sed -E 's#/+#/#g')"
    [[ -n "$p" ]] || p="/"
    [[ "$p" == /* ]] || p="/$p"

    if [[ "$p" != "/" ]]; then
        p="${p%/}/"
    fi

    printf '%s' "$p"
}

normalize_host() {
    local h="${1:-127.0.0.1}"
    h="${h#http://}"
    h="${h#https://}"
    h="${h%%/*}"
    h="${h%%\?*}"
    h="${h%%\#*}"
    printf '%s' "$h"
}

# ---------- 读取和保存配置 ----------

load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        # 配置文件由本脚本创建，请勿放入不可信内容。
        # shellcheck disable=SC1090
        source "$CONFIG_FILE"
    fi

    : "${XUI_HOST:=127.0.0.1}"
    : "${XUI_PANEL_PORT:=22682}"
    : "${XUI_BASE_PATH:=/DzFtThyY0rcdykt4CC/}"
    : "${XUI_USERNAME:=}"
    : "${XUI_PASSWORD:=}"

    XUI_HOST="$(normalize_host "$XUI_HOST")"
    XUI_BASE_PATH="$(normalize_path "$XUI_BASE_PATH")"

    rebuild_url
}

rebuild_url() {
    PANEL_ROOT="http://${XUI_HOST}:${XUI_PANEL_PORT}${XUI_BASE_PATH}"
}

save_config() {
    XUI_HOST="$(normalize_host "${XUI_HOST:-127.0.0.1}")"
    XUI_BASE_PATH="$(normalize_path "${XUI_BASE_PATH:-/}")"

    if ! [[ "$XUI_PANEL_PORT" =~ ^[0-9]+$ ]] ||
       (( XUI_PANEL_PORT < 1 || XUI_PANEL_PORT > 65535 )); then
        err "面板端口无效。"
        return 1
    fi

    {
        printf 'XUI_HOST=%q\n' "$XUI_HOST"
        printf 'XUI_PANEL_PORT=%q\n' "$XUI_PANEL_PORT"
        printf 'XUI_BASE_PATH=%q\n' "$XUI_BASE_PATH"
        printf 'XUI_USERNAME=%q\n' "$XUI_USERNAME"
        printf 'XUI_PASSWORD=%q\n' "$XUI_PASSWORD"
    } > "$CONFIG_FILE" || {
        err "无法写入配置文件。"
        return 1
    }

    chmod 600 "$CONFIG_FILE"
    rebuild_url
    ok "配置已保存并规范化：$CONFIG_FILE"
}

configure_panel() {
    local value

    echo
    echo "===== 配置 3x-ui 面板连接 ====="
    echo "当前地址：$PANEL_ROOT"
    echo "留空表示保留当前值。"
    echo

    read -r -p "面板主机/IP [${XUI_HOST}]: " value
    [[ -n "$value" ]] && XUI_HOST="$(normalize_host "$value")"

    read -r -p "面板端口 [${XUI_PANEL_PORT}]: " value
    [[ -n "$value" ]] && XUI_PANEL_PORT="$value"

    read -r -p "面板路径 [${XUI_BASE_PATH}]: " value
    [[ -n "$value" ]] && XUI_BASE_PATH="$value"

    read -r -p "面板用户名 [${XUI_USERNAME}]: " value
    [[ -n "$value" ]] && XUI_USERNAME="$value"

    read -r -s -p "面板密码（留空保持不变）: " value
    echo
    [[ -n "$value" ]] && XUI_PASSWORD="$value"
    unset value

    save_config
}

# ---------- 依赖检查 ----------

check_dependencies() {
    local missing=()
    local cmd

    for cmd in curl jq sed awk openssl; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done

    if (( ${#missing[@]} > 0 )); then
        warn "缺少依赖：${missing[*]}"
        read -r -p "是否使用 apt 安装依赖？[Y/n]: " answer

        if [[ ! "$answer" =~ ^[Nn]$ ]]; then
            apt-get update &&
                apt-get install -y curl jq sed gawk openssl ca-certificates || {
                err "依赖安装失败。"
                return 1
            }
        else
            return 1
        fi
    fi
}

# ---------- CSRF 与登录：重点修复区域 ----------

get_csrf() {
    local code token

    rebuild_url

    code="$(curl -sS \
        --connect-timeout 5 --max-time 15 \
        -b "$COOKIE_FILE" -c "$COOKIE_FILE" \
        -H 'Accept: application/json' \
        -o "$CSRF_FILE" \
        -w '%{http_code}' \
        "${PANEL_ROOT}csrf-token")" || {
        err "CSRF 请求无法连接面板。"
        return 1
    }

    if [[ "$code" != "200" ]]; then
        err "获取 CSRF Token 失败，HTTP 状态：$code"
        cat "$CSRF_FILE" 2>/dev/null
        echo
        return 1
    fi

    if ! jq -e '.success == true and (.obj | type == "string") and (.obj | length > 0)' \
        "$CSRF_FILE" >/dev/null 2>&1; then
        err "CSRF 响应格式异常："
        jq . "$CSRF_FILE" 2>/dev/null || cat "$CSRF_FILE"
        echo
        return 1
    fi

    token="$(jq -r '.obj' "$CSRF_FILE")"
    printf '%s' "$token"
}

api_login() {
    local csrf code payload

    if [[ -z "$XUI_USERNAME" || -z "$XUI_PASSWORD" ]]; then
        err "用户名或密码为空，请先进入菜单 1 配置面板。"
        return 1
    fi

    # 每次重新登录都使用干净的 Cookie 会话。
    rm -f "$COOKIE_FILE"
    touch "$COOKIE_FILE"
    chmod 600 "$COOKIE_FILE"

    info "正在获取 CSRF Token..."

    csrf="$(get_csrf)" || return 1

    payload="$(jq -cn \
        --arg username "$XUI_USERNAME" \
        --arg password "$XUI_PASSWORD" \
        '{username:$username,password:$password}')" || {
        err "无法生成登录请求。"
        return 1
    }

    info "正在登录 3x-ui 面板..."

    code="$(curl -sS \
        --connect-timeout 5 --max-time 30 \
        -b "$COOKIE_FILE" -c "$COOKIE_FILE" \
        -H 'Accept: application/json' \
        -H 'Content-Type: application/json' \
        -H "X-CSRF-Token: ${csrf}" \
        -X POST \
        --data "$payload" \
        -o "$BODY_FILE" \
        -w '%{http_code}' \
        "${PANEL_ROOT}login")" || {
        err "登录请求连接失败。"
        return 1
    }

    if [[ "$code" != "200" ]]; then
        err "登录请求失败，HTTP 状态：$code"
        cat "$BODY_FILE" 2>/dev/null
        echo
        return 1
    fi

    if ! jq -e '.success == true' "$BODY_FILE" >/dev/null 2>&1; then
        err "登录未成功，HTTP 状态：$code"
        jq . "$BODY_FILE" 2>/dev/null || cat "$BODY_FILE"
        echo
        warn "请核对用户名、密码，以及面板是否启用了双重验证。"
        return 1
    fi

    ok "面板登录成功。"
}

# ---------- 通用 API 请求 ----------

api_request() {
    local method="$1"
    local endpoint="$2"
    shift 2

    local csrf code

    csrf="$(get_csrf)" || return 1

    code="$(curl -sS \
        --connect-timeout 5 --max-time 30 \
        -b "$COOKIE_FILE" -c "$COOKIE_FILE" \
        -H 'Accept: application/json' \
        -H "X-CSRF-Token: ${csrf}" \
        "$@" \
        -X "$method" \
        -o "$BODY_FILE" \
        -w '%{http_code}' \
        "${PANEL_ROOT}${endpoint}")" || {
        err "API 请求连接失败：$endpoint"
        return 1
    }

    if [[ "$code" != "200" ]]; then
        err "API 请求失败，HTTP 状态：$code"
        cat "$BODY_FILE" 2>/dev/null
        echo
        return 1
    fi

    if ! jq -e '.success == true' "$BODY_FILE" >/dev/null 2>&1; then
        err "API 返回失败：$endpoint"
        jq . "$BODY_FILE" 2>/dev/null || cat "$BODY_FILE"
        echo
        return 1
    fi

    return 0
}

ensure_login() {
    api_login
}

# ---------- 入站列表 ----------

list_inbounds() {
    echo
    echo "===== 入站列表 ====="

    ensure_login || return 1

    if api_request GET "panel/api/inbounds/list"; then
        jq -r '
          if (.obj | type) == "array" then
            .obj[] |
            [
              ("ID: " + ((.id // "") | tostring)),
              ("端口: " + ((.port // "") | tostring)),
              ("协议: " + (.protocol // "")),
              ("备注: " + (.remark // "")),
              ("启用: " + ((.enable // false) | tostring))
            ] | join(" | ")
          else
            .
          end
        ' "$BODY_FILE"
    else
        return 1
    fi
}

# ---------- Xray 密钥与 UUID ----------

generate_uuid() {
    if command -v xray >/dev/null 2>&1; then
        xray uuid 2>/dev/null | head -n 1
    elif command -v uuidgen >/dev/null 2>&1; then
        uuidgen
    else
        cat /proc/sys/kernel/random/uuid
    fi
}

generate_reality_keys() {
    local output private_key public_key

    if ! command -v xray >/dev/null 2>&1; then
        err "未找到 xray 命令，无法自动生成 REALITY 密钥。"
        return 1
    fi

    output="$(xray x25519 2>&1)" || {
        err "执行 xray x25519 失败："
        printf '%s\n' "$output"
        return 1
    }

    private_key="$(printf '%s\n' "$output" |
        awk -F: '
        tolower($1) ~ /private.?key/ {
            sub(/^[^:]*:[[:space:]]*/, "")
            print
            exit
        }')"

    public_key="$(printf '%s\n' "$output" |
        awk -F: '
        tolower($1) ~ /public.?key/ {
            sub(/^[^:]*:[[:space:]]*/, "")
            print
            exit
        }
        tolower($1) == "password" {
            sub(/^[^:]*:[[:space:]]*/, "")
            password=$0
        }
        END {
            if (!found && password != "") print password
        }')"

    # 某些版本把公钥字段命名为 Password。
    if [[ -z "$private_key" ]]; then
        private_key="$(printf '%s\n' "$output" |
            awk -F: '
            tolower($1) ~ /private/ {
                sub(/^[^:]*:[[:space:]]*/, "")
                print
                exit
            }')"
    fi

    if [[ -z "$private_key" ]]; then
        err "无法识别 xray x25519 的私钥输出格式："
        printf '%s\n' "$output"
        return 1
    fi

    REALITY_PRIVATE_KEY="$private_key"
    REALITY_PUBLIC_KEY="$public_key"
}

# ---------- 创建 VLESS + REALITY ----------

create_reality() {
    local remark port address target uuid short_id
    local settings stream sniffing payload public_key

    echo
    echo "===== 创建 VLESS + REALITY 入站 ====="

    ensure_login || return 1

    if ! command -v xray >/dev/null 2>&1; then
        err "未找到 xray。请确认 3x-ui 已正确安装 Xray。"
        return 1
    fi

    read -r -p "入站备注 [VLESS-REALITY]: " remark
    remark="${remark:-VLESS-REALITY}"

    read -r -p "监听端口 [443]: " port
    port="${port:-443}"

    if ! [[ "$port" =~ ^[0-9]+$ ]] ||
       (( port < 1 || port > 65535 )); then
        err "端口必须为 1-65535 的整数。"
        return 1
    fi

    read -r -p "服务器公网 IP 或域名（用于输出分享链接）: " address
    if [[ -z "$address" ]]; then
        err "服务器公网 IP 或域名不能为空。"
        return 1
    fi

    read -r -p "REALITY 目标域名 [www.microsoft.com]: " target
    target="${target:-www.microsoft.com}"

    if [[ "$target" == *"://"* || "$target" == */* ]]; then
        err "目标域名只填写主机名，不要包含协议或路径。"
        return 1
    fi

    info "正在生成 UUID、REALITY 密钥和 Short ID..."

    uuid="$(generate_uuid)"
    [[ -n "$uuid" ]] || {
        err "生成 UUID 失败。"
        return 1
    }

    generate_reality_keys || return 1
    public_key="$REALITY_PUBLIC_KEY"

    if [[ -z "$public_key" ]]; then
        warn "当前 Xray 输出中未识别到公钥。"
        read -r -p "请输入对应的 REALITY 公钥（用于分享链接）: " public_key
        if [[ -z "$public_key" ]]; then
            err "没有公钥，无法生成完整分享链接。"
            return 1
        fi
    fi

    short_id="$(openssl rand -hex 8)" || {
        err "生成 Short ID 失败。"
        return 1
    }

    settings="$(jq -cn \
        --arg uuid "$uuid" \
        '{
          clients: [{
            id: $uuid,
            email: $uuid,
            enable: true,
            flow: "xtls-rprx-vision"
          }],
          decryption: "none",
          encryption: "none"
        }')" || return 1

    stream="$(jq -cn \
        --arg target "$target" \
        --arg privateKey "$REALITY_PRIVATE_KEY" \
        --arg shortId "$short_id" \
        '{
          network: "tcp",
          security: "reality",
          externalProxy: [],
          realitySettings: {
            show: false,
            xver: 0,
            dest: ($target + ":443"),
            serverNames: [$target],
            privateKey: $privateKey,
            shortIds: [$shortId],
            settings: {
              fingerprint: "chrome",
              serverName: $target,
              publicKey: "",
              spiderX: "/"
            }
          },
          tcpSettings: {
            acceptProxyProtocol: false,
            header: {type: "none"}
          }
        }')" || return 1

    sniffing='{"enabled":true,"destOverride":["http","tls","quic"],"metadataOnly":false,"routeOnly":false}'

    payload="$(jq -cn \
        --arg remark "$remark" \
        --argjson port "$port" \
        --arg settings "$settings" \
        --arg streamSettings "$stream" \
        --arg sniffing "$sniffing" \
        '{
          up: 0,
          down: 0,
          total: 0,
          remark: $remark,
          enable: true,
          expiryTime: 0,
          listen: "",
          port: $port,
          protocol: "vless",
          settings: $settings,
          streamSettings: $streamSettings,
          sniffing: $sniffing
        }')" || return 1

    echo
    echo "即将创建以下入站："
    echo "协议：VLESS + REALITY"
    echo "备注：$remark"
    echo "端口：$port"
    echo "目标域名：$target"
    echo "UUID：$uuid"
    echo "Short ID：$short_id"
    echo

    read -r -p "确认创建？[y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        info "已取消，没有发送创建请求。"
        return 0
    fi

    if ! api_request POST "panel/api/inbounds/add" \
        -H 'Content-Type: application/json' \
        --data "$payload"; then
        err "创建入站失败。请检查 API 返回信息、端口占用和当前 3x-ui 版本。"
        return 1
    fi

    ok "创建入站请求成功。"
    jq . "$BODY_FILE"

    echo
    echo "===== VLESS 分享链接 ====="

    local encoded_remark link
    encoded_remark="$(jq -rn --arg value "$remark" '$value | @uri')"

    link="vless://${uuid}@${address}:${port}?type=tcp&security=reality&pbk=${public_key}&fp=chrome&sni=${target}&sid=${short_id}&spx=%2F&flow=xtls-rprx-vision#${encoded_remark}"

    printf '%s\n' "$link"

    echo
    warn "请用客户端测试分享链接，并确认服务器防火墙已允许该端口。"
    warn "如果面板 API 拒绝创建，请检查当前版本所要求的 REALITY 字段。"
}

# ---------- 服务管理 ----------

service_menu() {
    local choice

    while true; do
        echo
        echo "===== X-UI 服务管理 ====="
        echo "1. 查看服务状态"
        echo "2. 查看最近日志"
        echo "3. 重启服务"
        echo "0. 返回"
        read -r -p "请选择 [0-3]: " choice

        case "$choice" in
            1)
                systemctl status x-ui --no-pager -l
                pause
                ;;
            2)
                journalctl -u x-ui -n 100 --no-pager
                pause
                ;;
            3)
                read -r -p "确认重启 x-ui？[y/N]: " confirm
                if [[ "$confirm" =~ ^[Yy]$ ]]; then
                    systemctl restart x-ui &&
                        ok "x-ui 重启命令已执行。" ||
                        err "x-ui 重启失败。"
                    systemctl --no-pager --full status x-ui
                fi
                pause
                ;;
            0) return ;;
            *) warn "无效选项。" ;;
        esac
    done
}

# ---------- 诊断 ----------

diagnostics() {
    echo
    echo "===== 配置与连接诊断 ====="
    echo "面板地址：$PANEL_ROOT"
    echo "用户名：$XUI_USERNAME"
    echo "密码：不显示"
    echo

    echo "===== 服务状态 ====="
    systemctl is-active x-ui 2>/dev/null || true

    echo
    echo "===== 面板 HTTP 状态 ====="
    curl -sS \
        --connect-timeout 5 --max-time 10 \
        -o /dev/null \
        -w 'HTTP_STATUS=%{http_code}\n' \
        "${PANEL_ROOT}csrf-token" || true

    echo
    echo "===== 数据库文件 ====="
    if [[ -f /etc/x-ui/x-ui.db ]]; then
        ls -lh /etc/x-ui/x-ui.db
    else
        warn "未找到 /etc/x-ui/x-ui.db"
    fi

    echo
    echo "===== Xray 版本 ====="
    if command -v xray >/dev/null 2>&1; then
        xray version 2>&1 | head -n 3
    else
        warn "未找到 xray 命令。"
    fi
}

# ---------- 主菜单 ----------

main_menu() {
    local choice

    while true; do
        rebuild_url

        echo
        echo "============================================================"
        echo "  瞎折腾吧 | X-UI 节点管理器"
        echo "============================================================"
        echo "面板：${PANEL_ROOT}"
        echo "1. 配置面板连接"
        echo "2. 配置、HTTP、CSRF 诊断"
        echo "3. 登录面板并列出入站"
        echo "4. 创建 VLESS + REALITY 入站"
        echo "5. 服务状态、日志与重启"
        echo "6. 保存并规范化当前配置"
        echo "0. 退出"
        echo "============================================================"

        read -r -p "请选择 [0-6]: " choice

        case "$choice" in
            1)
                configure_panel
                pause
                ;;
            2)
                diagnostics
                pause
                ;;
            3)
                list_inbounds
                pause
                ;;
            4)
                create_reality
                pause
                ;;
            5)
                service_menu
                ;;
            6)
                save_config
                pause
                ;;
            0)
                info "已退出。"
                return 0
                ;;
            *)
                warn "请输入 0-6。"
                ;;
        esac
    done
}

# ---------- 启动 ----------

main() {
    need_root
    check_dependencies || exit 1
    load_config
    main_menu
}

main "$@"
SCRIPT_EOF

chmod 700 /root/xiazheteng-node-manager.sh

bash -n /root/xiazheteng-node-manager.sh &&
echo '[成功] Bash 语法检查通过。' &&
bash /root/xiazheteng-node-manager.sh
