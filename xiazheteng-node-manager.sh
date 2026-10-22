```bash
cat > /usr/local/bin/xiazheteng-node-manager.sh <<'BASH'
#!/usr/bin/env bash
# ============================================================
# 瞎折腾吧 | 3x-ui / Xray 节点管理器
# 单文件版
# ============================================================

set -uo pipefail
umask 077

CONFIG_FILE="/etc/x-ui/node-manager.env"
INSTALL_RESULT="/etc/x-ui/install-result.env"
DB_FILE="/etc/x-ui/x-ui.db"

PANEL_PORT="22682"
BASE_PATH="/DzFtThyY0rcdykt4CC/"
USERNAME=""
PASSWORD=""
PANEL_ROOT=""
LOGIN_URL=""
CSRF_URL=""
API_PREFIX=""
CSRF_TOKEN=""
COOKIE=""
WORK=""
BODY=""
CURL_ERROR=""

info() { printf '\033[36m[信息]\033[0m %s\n' "$*"; }
ok()   { printf '\033[32m[成功]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[警告]\033[0m %s\n' "$*"; }
err()  { printf '\033[31m[错误]\033[0m %s\n' "$*" >&2; }

pause() {
    echo
    read -r -p "按回车键继续..." _
}

cleanup() {
    if [[ -n "${WORK:-}" && -d "$WORK" ]]; then
        rm -rf -- "$WORK"
    fi
}
trap cleanup EXIT

need_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        err "请使用 root 用户运行。"
        exit 1
    fi
}

check_dependencies() {
    local missing=()
    local cmd
    for cmd in curl jq openssl sed grep systemctl; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done

    if ((${#missing[@]})); then
        err "缺少依赖：${missing[*]}"
        echo "Debian/Ubuntu 安装命令："
        echo "apt-get update && apt-get install -y curl jq openssl"
        exit 1
    fi
}

# 只读取简单 KEY='VALUE' 配置，不执行配置文件
read_value() {
    local file="$1" key="$2"
    [[ -f "$file" ]] || return 0

    sed -nE \
      "s/^[[:space:]]*${key}=['\"]?(.*)['\"]?[[:space:]]*$/\1/p" \
      "$file" | head -n 1
}

normalize_config() {
    # 合并重复斜杠
    BASE_PATH="$(printf '%s' "$BASE_PATH" | sed -E 's#/{2,}#/#g')"

    # 统一为以一个斜杠开头、一个斜杠结尾
    BASE_PATH="/${BASE_PATH#/}"
    BASE_PATH="${BASE_PATH%/}/"

    if [[ ! "$PANEL_PORT" =~ ^[0-9]{1,5}$ ]] ||
       ((10#$PANEL_PORT < 1 || 10#$PANEL_PORT > 65535)); then
        warn "面板端口无效，改用 22682。"
        PANEL_PORT="22682"
    fi
}

load_config() {
    local value

    if [[ -f "$INSTALL_RESULT" ]]; then
        value="$(read_value "$INSTALL_RESULT" XUI_PANEL_PORT)"
        [[ -n "$value" ]] && PANEL_PORT="$value"

        value="$(read_value "$INSTALL_RESULT" XUI_WEB_BASE_PATH)"
        [[ -n "$value" ]] && BASE_PATH="$value"
    fi

    if [[ -f "$CONFIG_FILE" ]]; then
        value="$(read_value "$CONFIG_FILE" XUI_USERNAME)"
        [[ -n "$value" ]] && USERNAME="$value"

        value="$(read_value "$CONFIG_FILE" XUI_PASSWORD)"
        [[ -n "$value" ]] && PASSWORD="$value"

        value="$(read_value "$CONFIG_FILE" XUI_PANEL_PORT)"
        [[ -n "$value" ]] && PANEL_PORT="$value"

        value="$(read_value "$CONFIG_FILE" PANEL_PORT)"
        [[ -n "$value" ]] && PANEL_PORT="$value"

        value="$(read_value "$CONFIG_FILE" XUI_BASE_PATH)"
        [[ -n "$value" ]] && BASE_PATH="$value"

        value="$(read_value "$CONFIG_FILE" BASE_PATH)"
        [[ -n "$value" ]] && BASE_PATH="$value"
    fi

    normalize_config
}

save_config() {
    install -d -m 700 /etc/x-ui
    local tmp
    tmp="$(mktemp /etc/x-ui/node-manager.env.XXXXXX)" || return 1

    {
        printf "XUI_USERNAME='%s'\n" "${USERNAME//\'/}"
        printf "XUI_PASSWORD='%s'\n" "${PASSWORD//\'/}"
        printf "XUI_PANEL_PORT='%s'\n" "$PANEL_PORT"
        printf "XUI_BASE_PATH='%s'\n" "$BASE_PATH"
    } > "$tmp"

    chmod 600 "$tmp"
    mv -f "$tmp" "$CONFIG_FILE"
}

setup_urls() {
    load_config

    # 再次规范化，防止配置中的 // 进入请求 URL
    BASE_PATH="$(printf '%s' "$BASE_PATH" | sed -E 's#/{2,}#/#g')"
    BASE_PATH="/${BASE_PATH#/}"
    BASE_PATH="${BASE_PATH%/}/"

    PANEL_ROOT="http://127.0.0.1:${PANEL_PORT}${BASE_PATH%/}"
    LOGIN_URL="${PANEL_ROOT}/login"
    CSRF_URL="${PANEL_ROOT}/csrf-token"
    API_PREFIX="${PANEL_ROOT}/panel/api"

    info "面板端口：$PANEL_PORT"
    info "Base Path：$BASE_PATH"
    info "面板地址：$PANEL_ROOT"
}

# 返回 HTTP 状态码；失败时返回 000，并创建响应文件
http_request() {
    local method="$1" url="$2"
    shift 2

    : > "$BODY"
    : > "$CURL_ERROR"

    local status rc
    status="$(
        curl -sS \
          --connect-timeout 5 \
          --max-time 30 \
          -X "$method" \
          -b "$COOKIE" \
          -c "$COOKIE" \
          -o "$BODY" \
          -w '%{http_code}' \
          "$url" "$@" \
          2>"$CURL_ERROR"
    )"
    rc=$?

    [[ -f "$BODY" ]] || : > "$BODY"

    if [[ -z "$status" ]]; then
        status="000"
    fi

    if ((rc != 0)); then
        warn "curl 请求失败，退出码：$rc"
        [[ -s "$CURL_ERROR" ]] && sed -n '1,5p' "$CURL_ERROR" >&2
        status="000"
    fi

    printf '%s' "$status"
}

prompt_credentials() {
    echo
    echo "===== 面板账号 ====="

    if [[ -z "$USERNAME" ]]; then
        read -r -p "请输入 3x-ui 用户名：" USERNAME
    else
        read -r -p "当前用户名为 ${USERNAME}，回车使用该用户名，或输入新用户名：" value
        [[ -n "${value:-}" ]] && USERNAME="$value"
    fi

    if [[ -z "$PASSWORD" ]]; then
        read -r -s -p "请输入 3x-ui 密码：" PASSWORD
        echo
    else
        read -r -s -p "回车使用保存的密码，或输入新密码：" value
        echo
        [[ -n "${value:-}" ]] && PASSWORD="$value"
    fi

    if [[ -z "$USERNAME" || -z "$PASSWORD" ]]; then
        err "用户名或密码为空。"
        return 1
    fi

    save_config
}

get_csrf_token() {
    local status

    info "正在请求 CSRF Token……"
    status="$(http_request GET "$CSRF_URL")"

    if [[ "$status" != "200" ]]; then
        err "CSRF 接口 HTTP 状态：$status"
        [[ -s "$BODY" ]] && head -c 500 "$BODY" && echo
        return 1
    fi

    # 你的接口实际返回：
    # {"obj":"TOKEN","success":true}
    # 因此必须读取 .obj。
    CSRF_TOKEN="$(jq -r '
        if (.success == true) then
            (.obj // .token // .csrfToken // .csrf_token // .data.token // empty)
        else
            empty
        end
    ' "$BODY" 2>/dev/null || true)"

    if [[ -z "$CSRF_TOKEN" || "$CSRF_TOKEN" == "null" ]]; then
        err "接口返回 HTTP 200，但 JSON 中没有可用的 CSRF Token。"
        echo "响应内容："
        head -c 500 "$BODY"
        echo
        return 1
    fi

    ok "CSRF Token 获取成功。"
}

api_login() {
    setup_urls

    if [[ -z "$USERNAME" || -z "$PASSWORD" ]]; then
        prompt_credentials || return 1
    fi

    COOKIE="$WORK/cookies.txt"
    BODY="$WORK/response.json"
    CURL_ERROR="$WORK/curl-error.txt"
    : > "$COOKIE"

    if ! get_csrf_token; then
        err "CSRF 获取失败，请检查 Base Path 和面板服务。"
        return 1
    fi

    info "正在提交登录请求……"

    local status
    status="$(
        http_request POST "$LOGIN_URL" \
          -H "Content-Type: application/json" \
          -H "Accept: application/json" \
          -H "X-CSRF-Token: $CSRF_TOKEN" \
          --data "$(jq -cn \
            --arg username "$USERNAME" \
            --arg password "$PASSWORD" \
            '{username:$username,password:$password}')"
    )"

    if [[ "$status" != "200" ]]; then
        err "登录 HTTP 状态：$status"
        [[ -s "$BODY" ]] && head -c 500 "$BODY" && echo
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
    head -c 500 "$BODY"
    echo
    return 1
}

api_get() {
    local endpoint="$1" status
    status="$(http_request GET "${API_PREFIX}${endpoint}")"

    if [[ "$status" != "200" ]]; then
        err "API 请求失败：$endpoint，HTTP $status"
        [[ -s "$BODY" ]] && head -c 500 "$BODY" && echo
        return 1
    fi

    if ! jq -e . "$BODY" >/dev/null 2>&1; then
        err "API 返回的不是有效 JSON。"
        head -c 500 "$BODY"
        echo
        return 1
    fi

    if ! jq -e '
        .success == true or
        .success == "true" or
        .success == 1
    ' "$BODY" >/dev/null 2>&1; then
        err "API 返回失败：$(jq -r '.msg // .message // "未知错误"' "$BODY")"
        return 1
    fi
}

list_nodes() {
    api_login || return 1
    api_get "/inbounds/list" || return 1

    echo
    echo "================ 节点列表 ================"

    jq -r '
      (.obj // .data // [])[] |
      "ID: \(.id // "-") | 备注: \(.remark // "-") | 协议: \(.protocol // "-") | 端口: \(.port // "-") | 启用: \(.enable // false)"
    ' "$BODY" 2>/dev/null || {
        warn "无法解析节点列表，显示原始响应："
        jq . "$BODY"
    }

    echo "=========================================="
}

create_reality_node() {
    api_login || return 1

    local remark port sni uuid short_id xray_bin key_output private_key public_key
    local settings stream_settings sniffing status confirm

    echo
    echo "===== 创建 VLESS + REALITY 节点 ====="
    read -r -p "节点备注：" remark
    remark="${remark:-VLESS-REALITY}"

    while true; do
        read -r -p "监听端口（1024-65535）：" port
        if [[ "$port" =~ ^[0-9]+$ ]] &&
           ((port >= 1024 && port <= 65535)); then
            break
        fi
        warn "请输入有效端口。"
    done

    read -r -p "REALITY SNI [www.microsoft.com]：" sni
    sni="${sni:-www.microsoft.com}"

    if [[ ! "$sni" =~ ^[a-zA-Z0-9.-]+$ ]]; then
        err "SNI 格式无效。"
        return 1
    fi

    uuid="$(cat /proc/sys/kernel/random/uuid)"
    short_id="$(openssl rand -hex 8)" || return 1

    for xray_bin in \
        /usr/local/x-ui/bin/xray-linux-amd64 \
        /usr/local/x-ui/bin/xray \
        /usr/local/bin/xray \
        /usr/bin/xray; do
        [[ -x "$xray_bin" ]] && break
    done

    if [[ ! -x "${xray_bin:-}" ]]; then
        xray_bin="$(command -v xray 2>/dev/null || true)"
    fi

    if [[ -z "${xray_bin:-}" || ! -x "$xray_bin" ]]; then
        err "找不到 Xray 可执行文件。"
        return 1
    fi

    key_output="$("$xray_bin" x25519 2>&1)" || {
        err "生成 REALITY 密钥失败："
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
        err "无法识别当前 Xray 的 x25519 输出格式："
        echo "$key_output"
        return 1
    fi

    settings="$(
        jq -cn --arg uuid "$uuid" --arg remark "$remark" '{
          clients:[{
            id:$uuid,
            flow:"xtls-rprx-vision",
            email:$remark,
            enable:true,
            limitIp:0,
            totalGB:0,
            expiryTime:0,
            tgId:"",
            subId:""
          }],
          decryption:"none",
          encryption:"none"
        }'
    )"

    stream_settings="$(
        jq -cn \
          --arg sni "$sni" \
          --arg privateKey "$private_key" \
          --arg shortId "$short_id" '{
            network:"tcp",
            security:"reality",
            realitySettings:{
              show:false,
              xver:0,
              dest:($sni + ":443"),
              serverNames:[$sni],
              privateKey:$privateKey,
              shortIds:[$shortId]
            }
          }'
    )"

    sniffing='{"enabled":true,"destOverride":["http","tls","quic"],"metadataOnly":false,"routeOnly":false}'

    echo
    echo "备注：$remark"
    echo "协议：VLESS + REALITY"
    echo "端口：$port"
    echo "SNI：$sni"
    echo "UUID：$uuid"
    echo "shortId：$short_id"
    echo

    read -r -p "确认提交创建请求？[y/N]：" confirm
    case "$confirm" in
        y|Y|yes|YES) ;;
        *) info "已取消。"; return 0 ;;
    esac

    status="$(
        http_request POST "${API_PREFIX}/inbounds/add" \
          -H "X-CSRF-Token: $CSRF_TOKEN" \
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
          --data-urlencode "down=0"
    )"

    if [[ "$status" != "200" ]]; then
        err "创建请求失败，HTTP $status"
        [[ -s "$BODY" ]] && head -c 800 "$BODY" && echo
        return 1
    fi

    if ! jq -e '
        .success == true or
        .success == "true" or
        .success == 1
    ' "$BODY" >/dev/null 2>&1; then
        err "面板未确认创建成功："
        jq . "$BODY" 2>/dev/null || cat "$BODY"
        return 1
    fi

    ok "面板已接受创建请求。"
    echo "UUID：$uuid"
    echo "端口：$port"
    echo "SNI：$sni"
    echo "公钥：$public_key"
    echo "shortId：$short_id"
    warn "请在面板确认入站配置有效后再使用。"
}

check_config() {
    setup_urls

    echo
    echo "===== 配置文件 ====="
    ls -l "$CONFIG_FILE" "$INSTALL_RESULT" "$DB_FILE" 2>/dev/null || true

    echo
    echo "===== 服务状态 ====="
    systemctl is-active x-ui 2>/dev/null || true

    echo
    echo "===== 面板首页测试 ====="
    curl -sS --connect-timeout 3 --max-time 5 \
      -o /dev/null -w 'HTTP_CODE=%{http_code}\n' \
      "${PANEL_ROOT}/" 2>&1 || true

    echo
    echo "===== CSRF 接口测试 ====="
    curl -sS --connect-timeout 3 --max-time 5 \
      -w '\nHTTP_CODE=%{http_code}\n' \
      "${CSRF_URL}" 2>&1 || true
}

show_status() {
    echo
    systemctl status x-ui --no-pager -l 2>&1 | head -n 40 || true

    echo
    echo "===== 最近 60 行日志 ====="
    journalctl -u x-ui -n 60 --no-pager 2>&1 || true
}

restart_service() {
    local answer
    read -r -p "确认重启 x-ui？[y/N]：" answer

    case "$answer" in
        y|Y|yes|YES)
            if systemctl restart x-ui; then
                sleep 2
                systemctl is-active --quiet x-ui &&
                    ok "x-ui 正在运行。" ||
                    err "服务未处于 active 状态，请检查日志。"
            else
                err "重启失败。"
            fi
            ;;
        *) info "已取消。" ;;
    esac
}

main_menu() {
    while true; do
        echo
        echo "================================================"
        echo "       瞎折腾吧 | 3x-ui 节点管理器"
        echo "================================================"
        echo "面板端口：$PANEL_PORT"
        echo "Base Path：$BASE_PATH"
        echo "------------------------------------------------"
        echo "1. 检查配置与 CSRF 接口"
        echo "2. 登录并列出节点"
        echo "3. 创建 VLESS + REALITY 节点"
        echo "4. 查看服务状态与日志"
        echo "5. 重启 x-ui"
        echo "6. 更换本次使用的面板账号"
        echo "7. 退出"
        echo "------------------------------------------------"

        local choice
        read -r -p "请选择：" choice

        case "$choice" in
            1) check_config; pause ;;
            2) list_nodes; pause ;;
            3) create_reality_node; pause ;;
            4) show_status; pause ;;
            5) restart_service; pause ;;
            6)
                USERNAME=""
                PASSWORD=""
                prompt_credentials
                pause
                ;;
            7) info "已退出。"; return 0 ;;
            *) warn "无效选项。" ;;
        esac
    done
}

main() {
    need_root
    check_dependencies

    if ! command -v x-ui >/dev/null 2>&1; then
        err "没有找到 x-ui 命令。请先安装 3x-ui。"
        exit 1
    fi

    WORK="$(mktemp -d /tmp/xui-manager.XXXXXX)"
    chmod 700 "$WORK"
    BODY="$WORK/response.json"
    COOKIE="$WORK/cookies.txt"
    CURL_ERROR="$WORK/curl-error.txt"

    load_config
    setup_urls

    if [[ -z "$USERNAME" || -z "$PASSWORD" ]]; then
        prompt_credentials || exit 1
    fi

    main_menu
}

main "$@"
BASH

chmod 700 /usr/local/bin/xiazheteng-node-manager.sh
bash -n /usr/local/bin/xiazheteng-node-manager.sh &&
echo '[成功] Bash 语法检查通过'
```

运行：

```bash
/usr/local/bin/xiazheteng-node-manager.sh
```

如果需要让 `x` 直接打开管理器：

```bash
cat > /usr/local/bin/x <<'EOF'
#!/usr/bin/env bash
exec /usr/local/bin/xiazheteng-node-manager.sh "$@"
EOF
chmod 700 /usr/local/bin/x
```

注意：这份脚本的 CSRF 解析已包含你实际接口返回的 `.obj` 字段。节点创建 API 的字段兼容性仍需以你安装的 3x-ui 版本实际响应验证；首次建议先用菜单 1 测试配置，再用菜单 2 测试登录和读取节点，确认正常后再创建节点。
