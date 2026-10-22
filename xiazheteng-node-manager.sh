SCRIPT=/usr/local/bin/xiazheteng-node-manager.sh

if [ -f "$SCRIPT" ]; then
    cp -a "$SCRIPT" "$SCRIPT.bak.$(date +%Y%m%d%H%M%S)"
fi

cat > "$SCRIPT" <<'BASH'
#!/usr/bin/env bash
# ============================================================
# 瞎折腾吧 | 3x-ui / Xray 节点管理器
# 单文件版本
# 功能：
#   1. 检查配置并登录面板
#   2. 列出节点
#   3. 创建 VLESS + REALITY 节点
#   4. 查看服务状态与日志
#   5. 重启 3x-ui
#   6. 退出
# ============================================================

set -uo pipefail
umask 077

SCRIPT_NAME="xiazheteng-node-manager"
CONFIG_FILE="/etc/x-ui/node-manager.env"
INSTALL_RESULT="/etc/x-ui/install-result.env"
DB_FILE="/etc/x-ui/x-ui.db"
SERVICE_NAME="x-ui"

PANEL_PORT="22682"
BASE_PATH="/DzFtThyY0rcdykt4CC/"

USERNAME=""
PASSWORD=""
COOKIE=""
WORK=""
BODY=""
CURL_ERROR=""
PANEL_ROOT=""
LOGIN_URL=""
CSRF_URL=""
API_PREFIX=""
CSRF_TOKEN=""

# -------------------- 基础工具 --------------------

info() { printf '\033[36m[信息]\033[0m %s\n' "$*"; }
ok()   { printf '\033[32m[成功]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[警告]\033[0m %s\n' "$*"; }
err()  { printf '\033[31m[错误]\033[0m %s\n' "$*" >&2; }

pause() {
    echo
    read -r -p "按回车键继续..." _
}

need_root() {
    if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
        err "请使用 root 用户运行。"
        exit 1
    fi
}

check_dependencies() {
    local missing=()
    local cmd

    for cmd in curl jq openssl python3; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done

    if ((${#missing[@]})); then
        err "缺少依赖：${missing[*]}"
        echo "Debian/Ubuntu 可执行："
        echo "apt-get update && apt-get install -y curl jq openssl python3"
        exit 1
    fi
}

cleanup() {
    if [[ -n "${WORK:-}" && -d "$WORK" ]]; then
        rm -rf -- "$WORK"
    fi
}
trap cleanup EXIT

# -------------------- 配置读取与保存 --------------------

read_config_value() {
    local file="$1"
    local key="$2"

    [[ -f "$file" ]] || return 0

    # 只读取指定变量，不 source 外部文件
    sed -nE \
        "s/^[[:space:]]*${key}=['\"]?([^'\"]*)['\"]?[[:space:]]*$/\1/p" \
        "$file" | head -n 1
}

load_config() {
    local value

    if [[ -f "$INSTALL_RESULT" ]]; then
        value="$(read_config_value "$INSTALL_RESULT" XUI_PANEL_PORT)"
        [[ -n "$value" ]] && PANEL_PORT="$value"

        value="$(read_config_value "$INSTALL_RESULT" XUI_WEB_BASE_PATH)"
        [[ -n "$value" ]] && BASE_PATH="$value"
    fi

    if [[ -f "$CONFIG_FILE" ]]; then
        value="$(read_config_value "$CONFIG_FILE" PANEL_PORT)"
        [[ -n "$value" ]] && PANEL_PORT="$value"

        value="$(read_config_value "$CONFIG_FILE" BASE_PATH)"
        [[ -n "$value" ]] && BASE_PATH="$value"
    fi

    normalize_config
}

normalize_config() {
    # 合并连续斜杠，修复 /path// 这类路径
    BASE_PATH="$(printf '%s' "$BASE_PATH" |
        sed -E 's#/{2,}#/#g')"

    [[ -n "$BASE_PATH" ]] || BASE_PATH="/"

    # 确保开头只有一个斜杠
    BASE_PATH="/${BASE_PATH#/}"

    # 确保结尾只有一个斜杠
    BASE_PATH="${BASE_PATH%/}/"

    if [[ ! "$PANEL_PORT" =~ ^[0-9]{1,5}$ ]] ||
       ((PANEL_PORT < 1 || PANEL_PORT > 65535)); then
        warn "面板端口配置无效，使用默认端口 22682。"
        PANEL_PORT="22682"
    fi
}

save_config() {
    install -d -m 700 /etc/x-ui

    cat > "$CONFIG_FILE" <<EOF
PANEL_PORT='$PANEL_PORT'
BASE_PATH='$BASE_PATH'
EOF

    chmod 600 "$CONFIG_FILE"
}

# -------------------- 面板 URL --------------------

setup_urls() {
    load_config

    # BASE_PATH 已规范化，去掉尾部斜杠后再拼接。
    # 例如：
    # /DzFtThyY0rcdykt4CC//
    # 会被规范化为：
    # /DzFtThyY0rcdykt4CC/
    local base="${BASE_PATH%/}"

    if [[ -z "$base" ]]; then
        PANEL_ROOT="http://127.0.0.1:${PANEL_PORT}"
    else
        PANEL_ROOT="http://127.0.0.1:${PANEL_PORT}${base}"
    fi

    LOGIN_URL="${PANEL_ROOT}/login"
    CSRF_URL="${PANEL_ROOT}/csrf-token"
    API_PREFIX="${PANEL_ROOT}/panel/api"

    info "面板端口：$PANEL_PORT"
    info "Base Path：$BASE_PATH"
    info "面板地址：$PANEL_ROOT"
}

# -------------------- HTTP 请求 --------------------

http_request() {
    local method="$1"
    local url="$2"
    shift 2

    : > "$BODY"
    : > "$CURL_ERROR"

    local status
    local rc

    status="$(
        curl -sS \
            --connect-timeout 5 \
            --max-time 30 \
            -X "$method" \
            -b "$COOKIE" \
            -c "$COOKIE" \
            -H "Accept: application/json" \
            -o "$BODY" \
            -w '%{http_code}' \
            "$url" \
            "$@" \
            2>"$CURL_ERROR"
    )"
    rc=$?

    if [[ -z "$status" ]]; then
        status="000"
    fi

    if ((rc != 0)); then
        warn "HTTP 请求失败，curl 退出码：$rc"
        if [[ -s "$CURL_ERROR" ]]; then
            sed -n '1,5p' "$CURL_ERROR" >&2
        fi
    fi

    # 防止 curl 失败时后续程序读取不存在的响应文件
    [[ -f "$BODY" ]] || : > "$BODY"

    printf '%s' "$status"
}

# -------------------- 检查面板服务 --------------------

check_service() {
    if ! command -v x-ui >/dev/null 2>&1; then
        err "没有找到 x-ui 命令。"
        return 1
    fi

    if ! systemctl list-unit-files "$SERVICE_NAME.service" \
        --no-legend 2>/dev/null | grep -q 'x-ui.service'; then
        warn "没有检测到标准 x-ui.service 服务单元。"
    fi

    if ! systemctl is-active --quiet "$SERVICE_NAME"; then
        warn "x-ui 服务当前未处于 active 状态。"
        echo "可执行：systemctl status x-ui --no-pager -l"
        return 1
    fi

    ok "x-ui 服务正在运行。"
    return 0
}

# -------------------- 启动时自定义账号 --------------------

prompt_custom_credentials() {
    echo
    echo "===== 设置本次管理器使用的面板账号 ====="
    echo "提示：这里输入的是你希望设置的账号。"
    echo "若当前 3x-ui 版本不支持非交互设置命令，脚本会提示你使用官方菜单。"
    echo

    while true; do
        read -r -p "面板用户名（3-64 位）： " USERNAME

        if [[ "$USERNAME" =~ ^[a-zA-Z0-9_.@-]{3,64}$ ]]; then
            break
        fi

        warn "用户名格式不正确，只允许字母、数字、下划线、点、@ 和连字符。"
    done

    while true; do
        read -r -s -p "面板密码（至少 12 位）： " PASSWORD
        echo

        if ((${#PASSWORD} < 12)); then
            warn "密码至少需要 12 位。"
            continue
        fi

        local confirm
        read -r -s -p "再次输入密码： " confirm
        echo

        if [[ "$PASSWORD" == "$confirm" ]]; then
            unset confirm
            break
        fi

        unset confirm
        warn "两次输入的密码不一致，请重新输入。"
    done
}

apply_custom_credentials() {
    echo
    read -r -p "是否尝试使用 x-ui 命令设置刚输入的账号密码？[y/N]：" answer

    case "$answer" in
        y|Y|yes|YES)
            if ! command -v x-ui >/dev/null 2>&1; then
                err "找不到 x-ui 命令，不能设置账号。"
                return 1
            fi

            info "尝试调用 x-ui setting 设置账号……"

            if x-ui setting -username "$USERNAME" -password "$PASSWORD"; then
                ok "设置命令已执行。正在重启 x-ui……"
                systemctl restart x-ui || {
                    err "重启失败，请检查 systemctl status x-ui。"
                    return 1
                }
                sleep 2
                ok "已执行账号设置及服务重启。"
            else
                err "当前版本未能通过该命令设置账号密码。"
                echo "为避免修改数据库或覆盖现有配置，请使用官方 x-ui 管理菜单中的账号密码重置功能。"
                echo "执行：x-ui"
                echo "不要将刚输入的账号密码视为已经生效。"
                return 1
            fi
            ;;
        *)
            info "跳过账号修改。"
            ;;
    esac
}

# -------------------- 登录及 CSRF --------------------

get_csrf_token() {
    local status token

    info "正在获取 CSRF Token……"

    status="$(http_request GET "$CSRF_URL")"

    if [[ "$status" != "200" ]]; then
        warn "CSRF Token 接口返回 HTTP $status。"
        if [[ -s "$BODY" ]]; then
            head -c 500 "$BODY"
            echo
        fi
        return 1
    fi

    token="$(jq -r '
        .token //
        .csrfToken //
        .csrf_token //
        .data.token //
        empty
    ' "$BODY" 2>/dev/null || true)"

    if [[ -z "$token" || "$token" == "null" ]]; then
        warn "接口返回内容中没有找到常见的 CSRF Token 字段。"
        echo "响应内容："
        head -c 500 "$BODY"
        echo
        return 1
    fi

    CSRF_TOKEN="$token"
    ok "已获取 CSRF Token。"
}

api_login() {
    local status

    setup_urls

    if [[ -z "$USERNAME" || -z "$PASSWORD" ]]; then
        err "当前没有可用的用户名或密码。"
        return 1
    fi

    COOKIE="$WORK/cookies.txt"
    BODY="$WORK/response.json"
    CURL_ERROR="$WORK/curl-error.txt"

    : > "$COOKIE"
    : > "$BODY"

    if ! get_csrf_token; then
        warn "无法取得 CSRF Token，未继续提交登录请求。"
        echo "请确认面板地址和 Base Path 正确，且本机可以访问面板。"
        return 1
    fi

    info "正在登录 3x-ui……"

    status="$(
        http_request POST "$LOGIN_URL" \
            -H "Content-Type: application/json" \
            -H "X-CSRF-Token: $CSRF_TOKEN" \
            --data "$(jq -cn \
                --arg username "$USERNAME" \
                --arg password "$PASSWORD" \
                '{username:$username,password:$password}')"
    )"

    if [[ "$status" != "200" ]]; then
        err "登录请求失败，HTTP 状态：$status"
        [[ -s "$BODY" ]] && head -c 600 "$BODY" && echo
        return 1
    fi

    if jq -e '
        .success == true or
        .success == "true" or
        .success == 1
    ' "$BODY" >/dev/null 2>&1; then
        ok "面板登录成功。"
        return 0
    fi

    err "面板没有确认登录成功。"
    head -c 600 "$BODY"
    echo
    return 1
}

# -------------------- API 通用函数 --------------------

api_get() {
    local endpoint="$1"
    local status

    status="$(http_request GET "${API_PREFIX}${endpoint}")"

    if [[ "$status" != "200" ]]; then
        err "API 请求失败：${endpoint}，HTTP $status"
        [[ -s "$BODY" ]] && head -c 500 "$BODY" && echo
        return 1
    fi

    if ! jq -e . "$BODY" >/dev/null 2>&1; then
        err "API 返回的内容不是有效 JSON。"
        head -c 500 "$BODY"
        echo
        return 1
    fi

    if ! jq -e '.success == true or .success == "true" or .success == 1' \
        "$BODY" >/dev/null 2>&1; then
        err "API 返回失败。"
        jq -r '.msg // .message // "没有提供错误说明"' "$BODY" 2>/dev/null
        return 1
    fi

    return 0
}

api_post_form() {
    local endpoint="$1"
    shift

    local status

    status="$(
        http_request POST "${API_PREFIX}${endpoint}" \
            -H "X-CSRF-Token: $CSRF_TOKEN" \
            "$@"
    )"

    if [[ "$status" != "200" ]]; then
        err "API 请求失败：${endpoint}，HTTP $status"
        [[ -s "$BODY" ]] && head -c 600 "$BODY" && echo
        return 1
    fi

    if ! jq -e '.success == true or .success == "true" or .success == 1' \
        "$BODY" >/dev/null 2>&1; then
        err "API 操作未成功。"
        jq -r '.msg // .message // "没有提供错误说明"' "$BODY" 2>/dev/null
        return 1
    fi

    ok "API 操作成功。"
    return 0
}

# -------------------- 查看节点 --------------------

list_nodes() {
    if ! api_login; then
        return 1
    fi

    if ! api_get "/inbounds/list"; then
        return 1
    fi

    echo
    echo "================ 节点列表 ================"

    jq -r '
      (.obj // .data // [])[] |
      [
        ("ID: " + ((.id // "")|tostring)),
        ("备注: " + (.remark // "")),
        ("协议: " + (.protocol // "")),
        ("端口: " + ((.port // "")|tostring)),
        ("启用: " + ((.enable // false)|tostring)),
        ("到期: " + ((.expiryTime // 0)|tostring))
      ] | join(" | ")
    ' "$BODY" 2>/dev/null || {
        warn "无法按预期格式解析节点列表，返回原始 JSON："
        jq . "$BODY"
    }

    echo "=========================================="
}

# -------------------- 创建 VLESS + REALITY --------------------

create_reality_node() {
    local port remark sni short_id uuid
    local key_output private_key public_key
    local settings stream_settings sniffing
    local server_ip

    if ! api_login; then
        return 1
    fi

    echo
    echo "===== 创建 VLESS + REALITY 节点 ====="

    read -r -p "节点备注：" remark
    [[ -n "$remark" ]] || remark="VLESS-REALITY"

    while true; do
        read -r -p "监听端口（1024-65535）：" port

        if [[ "$port" =~ ^[0-9]+$ ]] &&
           ((port >= 1024 && port <= 65535)); then
            break
        fi

        warn "端口必须是 1024-65535 之间的整数。"
    done

    read -r -p "REALITY SNI [www.microsoft.com]：" sni
    sni="${sni:-www.microsoft.com}"

    if [[ ! "$sni" =~ ^[a-zA-Z0-9.-]+$ ]]; then
        err "SNI 格式不正确。"
        return 1
    fi

    uuid="$(cat /proc/sys/kernel/random/uuid)"

    short_id="$(openssl rand -hex 8 2>/dev/null)"
    if [[ ! "$short_id" =~ ^[a-fA-F0-9]{16}$ ]]; then
        err "生成 shortId 失败。"
        return 1
    fi

    local xray_bin=""
    for candidate in \
        /usr/local/x-ui/bin/xray-linux-amd64 \
        /usr/local/x-ui/bin/xray \
        /usr/local/bin/xray \
        /usr/bin/xray; do
        if [[ -x "$candidate" ]]; then
            xray_bin="$candidate"
            break
        fi
    done

    if [[ -z "$xray_bin" ]]; then
        xray_bin="$(command -v xray 2>/dev/null || true)"
    fi

    if [[ -z "$xray_bin" ]]; then
        err "没有找到 Xray 可执行文件，无法生成 REALITY 密钥。"
        return 1
    fi

    key_output="$("$xray_bin" x25519 2>&1)" || {
        err "Xray 生成 REALITY 密钥失败："
        echo "$key_output"
        return 1
    }

    private_key="$(printf '%s\n' "$key_output" |
        sed -nE 's/^[[:space:]]*Private[[:space:]_-]*Key:[[:space:]]*//Ip' |
        head -n 1)"

    public_key="$(printf '%s\n' "$key_output" |
        sed -nE 's/^[[:space:]]*(Password|Public[[:space:]_-]*Key):[[:space:]]*//Ip' |
        head -n 1)"

    if [[ -z "$private_key" || -z "$public_key" ]]; then
        err "无法识别当前 Xray 的 x25519 密钥输出格式。"
        echo "Xray 原始输出："
        echo "$key_output"
        return 1
    fi

    settings="$(
        jq -cn \
          --arg uuid "$uuid" \
          --arg remark "$remark" \
          '{
            clients: [{
              id: $uuid,
              flow: "xtls-rprx-vision",
              email: $remark,
              enable: true,
              limitIp: 0,
              totalGB: 0,
              expiryTime: 0,
              tgId: "",
              subId: ""
            }],
            decryption: "none",
            encryption: "none"
          }'
    )"

    stream_settings="$(
        jq -cn \
          --arg sni "$sni" \
          --arg privateKey "$private_key" \
          --arg shortId "$short_id" \
          '{
            network: "tcp",
            security: "reality",
            realitySettings: {
              show: false,
              xver: 0,
              dest: ($sni + ":443"),
              serverNames: [$sni],
              privateKey: $privateKey,
              shortIds: [$shortId]
            }
          }'
    )"

    sniffing='{"enabled":true,"destOverride":["http","tls","quic"],"metadataOnly":false,"routeOnly":false}'

    echo
    echo "===== 即将创建的节点 ====="
    echo "备注：$remark"
    echo "协议：VLESS + REALITY"
    echo "端口：$port"
    echo "SNI：$sni"
    echo "UUID：$uuid"
    echo "shortId：$short_id"
    echo

    read -r -p "确认创建？[y/N]：" confirm
    case "$confirm" in
        y|Y|yes|YES) ;;
        *) info "已取消创建。"; return 0 ;;
    esac

    if ! api_post_form "/inbounds/add" \
        --data-urlencode "remark=$remark" \
        --data-urlencode "enable=true" \
        --data-urlencode "listen=" \
        --data-urlencode "port=$port" \
        --data-urlencode "protocol=vless" \
        --data-urlencode "settings=$settings" \
        --data-urlencode "streamSettings=$stream_settings" \
        --data-urlencode "sniffing=$sniffing" \
        --data-urlencode "expiryTime=0" \
        --data-urlencode "total=0" \
        --data-urlencode "up=0" \
        --data-urlencode "down=0"; then
        err "创建节点失败。请检查端口占用、面板 API 响应和 Xray 配置。"
        return 1
    fi

    echo
    ok "创建请求已被面板接受。"
    echo "UUID：$uuid"
    echo "端口：$port"
    echo "SNI：$sni"
    echo "公钥：$public_key"
    echo "shortId：$short_id"
    echo
    warn "请在面板中确认节点已保存并可运行，再将连接信息提供给客户端。"
}

# -------------------- 服务状态与日志 --------------------

show_status() {
    echo
    echo "===== systemd 状态 ====="
    systemctl status x-ui --no-pager -l 2>&1 | head -n 40 || true

    echo
    echo "===== 监听端口 ====="
    if command -v ss >/dev/null 2>&1; then
        ss -lntp 2>/dev/null | grep -E "(:${PANEL_PORT}[[:space:]]|xray|x-ui)" || true
    fi

    echo
    echo "===== 最近 60 行日志 ====="
    journalctl -u x-ui -n 60 --no-pager 2>&1 || true
}

restart_service() {
    echo
    read -r -p "确认重启 x-ui？[y/N]：" confirm

    case "$confirm" in
        y|Y|yes|YES)
            if systemctl restart x-ui; then
                sleep 2
                systemctl is-active --quiet x-ui &&
                    ok "x-ui 已成功重启。" ||
                    err "重启命令已执行，但服务未处于 active 状态。"
            else
                err "重启失败。"
            fi
            ;;
        *)
            info "已取消。"
            ;;
    esac
}

# -------------------- 配置检查 --------------------

check_config() {
    echo
    echo "===== 1. 配置文件 ====="
    ls -l "$INSTALL_RESULT" "$CONFIG_FILE" "$DB_FILE" 2>/dev/null || true

    echo
    echo "===== 2. 面板配置 ====="
    setup_urls

    echo
    echo "===== 3. 本地 HTTP 测试 ====="
    local code
    code="$(
        curl -sS \
            --connect-timeout 3 \
            --max-time 5 \
            -o /dev/null \
            -w '%{http_code}' \
            "$PANEL_ROOT/" 2>/dev/null
    )" || code="000"

    echo "请求地址：$PANEL_ROOT/"
    echo "HTTP 状态：${code:-000}"

    echo
    echo "===== 4. 服务状态 ====="
    systemctl is-active x-ui 2>/dev/null || true

    echo
    echo "===== 5. Base Path 规范化结果 ====="
    printf 'BASE_PATH=%s\n' "$BASE_PATH"
    printf 'LOGIN_URL=%s\n' "$LOGIN_URL"
    printf 'CSRF_URL=%s\n' "$CSRF_URL"
    printf 'API_PREFIX=%s\n' "$API_PREFIX"
}

# -------------------- 主菜单 --------------------

main_menu() {
    while true; do
        clear 2>/dev/null || true

        echo "================================================"
        echo "       瞎折腾吧 | 3x-ui 节点管理器"
        echo "================================================"
        echo "面板端口：$PANEL_PORT"
        echo "Base Path：$BASE_PATH"
        echo "------------------------------------------------"
        echo "1. 检查配置"
        echo "2. 登录面板并列出节点"
        echo "3. 创建 VLESS + REALITY 节点"
        echo "4. 查看服务状态与日志"
        echo "5. 重启 x-ui"
        echo "6. 重新输入面板账号密码"
        echo "7. 退出"
        echo "------------------------------------------------"

        local choice
        read -r -p "请选择：" choice

        case "$choice" in
            1)
                check_config
                pause
                ;;
            2)
                list_nodes
                pause
                ;;
            3)
                create_reality_node
                pause
                ;;
            4)
                show_status
                pause
                ;;
            5)
                restart_service
                pause
                ;;
            6)
                prompt_custom_credentials
                save_config
                info "账号信息仅保留在当前进程中，不会写入配置文件。"
                pause
                ;;
            7)
                info "已退出。"
                return 0
                ;;
            *)
                warn "无效选项。"
                sleep 1
                ;;
        esac
    done
}

# -------------------- 启动流程 --------------------

main() {
    need_root
    check_dependencies

    if ! command -v x-ui >/dev/null 2>&1; then
        err "没有检测到 x-ui 命令。"
        echo "请先安装 3x-ui，再运行本管理器。"
        exit 1
    fi

    WORK="$(mktemp -d /tmp/xui-manager.XXXXXX)"
    chmod 700 "$WORK"

    BODY="$WORK/response.json"
    COOKIE="$WORK/cookies.txt"
    CURL_ERROR="$WORK/curl-error.txt"

    load_config
    setup_urls

    prompt_custom_credentials

    echo
    echo "是否尝试应用刚输入的用户名和密码？"
    echo "如果当前 x-ui 版本不支持该命令，脚本会提示失败，不会修改数据库。"
    apply_custom_credentials || true

    # 账号密码只在内存中保留；不会明文写入配置文件
    save_config

    main_menu
}

main "$@"
BASH

chmod 700 "$SCRIPT"
bash -n "$SCRIPT" && echo "语法检查通过" || echo "语法错误，请勿运行"
