
#!/usr/bin/env bash
# ============================================================
# 瞎折腾吧 | 3x-ui 节点管理器
# 启动时自定义账号密码 -> 检测/安装 3x-ui -> 修改凭据 -> 节点菜单
# ============================================================

set -uo pipefail
umask 077

APP_NAME="瞎折腾吧 | 3x-ui 节点管理器"
INSTALL_URL="https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh"
CRED_FILE="/etc/x-ui/node-manager.env"
INSTALL_RESULT="/etc/x-ui/install-result.env"
DB="/etc/x-ui/x-ui.db"

PANEL_PORT="22682"
BASE_PATH="/DzFtThyY0rcdykt4CC/"
USERNAME=""
PASSWORD=""
CSRF_TOKEN=""
LOGIN_OK=0

WORK="$(mktemp -d /tmp/xui-manager.XXXXXX)"
COOKIE="$WORK/cookies.txt"
BODY="$WORK/response.json"
JSON_FILE="$WORK/request.json"

mkdir -p "$WORK"
chmod 700 "$WORK"
trap 'rm -rf "$WORK"' EXIT

info(){ echo "[信息] $*"; }
ok(){ echo "[成功] $*"; }
warn(){ echo "[提示] $*"; }
err(){ echo "[错误] $*" >&2; }

pause(){
    echo
    read -r -p "按回车键继续……" _
}

need_root(){
    if [[ "$EUID" -ne 0 ]]; then
        err "请使用 root 运行：sudo bash $0"
        exit 1
    fi
}

need_dependencies(){
    local missing=()
    for cmd in curl python3; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    if ((${#missing[@]})); then
        err "缺少依赖：${missing[*]}"
        echo "Debian/Ubuntu 安装命令：apt-get update && apt-get install -y curl python3"
        exit 1
    fi
}

# 读取安装程序保存的凭据；只读取，不输出密码。
load_install_result(){
    [[ -r "$INSTALL_RESULT" ]] || return 0

    local line key val
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[[:space:]]*# || -z "$line" ]] && continue
        if [[ "$line" =~ ^[[:space:]]*(XUI_USERNAME|XUI_PASSWORD|XUI_PANEL_PORT|XUI_WEB_BASE_PATH)[[:space:]]*=[[:space:]]*(.*)$ ]]; then
            key="${BASH_REMATCH[1]}"
            val="${BASH_REMATCH[2]}"
            val="${val%\"}"; val="${val#\"}"
            val="${val%\'}"; val="${val#\'}"
            case "$key" in
                XUI_PANEL_PORT) [[ -n "$PANEL_PORT" ]] || PANEL_PORT="$val" ;;
                XUI_WEB_BASE_PATH) [[ -n "$BASE_PATH" ]] || BASE_PATH="$val" ;;
            esac
        fi
    done < "$INSTALL_RESULT"
}

# 读取本脚本之前保存的设置。
load_saved_config(){
    [[ -r "$CRED_FILE" ]] || return 0
    [[ "$(stat -c '%a' "$CRED_FILE" 2>/dev/null || echo 777)" == "600" ]] || {
        warn "凭据文件权限不安全，跳过读取：$CRED_FILE"
        return 0
    }

    local line key val
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[[:space:]]*# || -z "$line" ]] && continue
        if [[ "$line" =~ ^[[:space:]]*(XUI_USERNAME|XUI_PASSWORD|XUI_PANEL_PORT|XUI_BASE_PATH)[[:space:]]*=[[:space:]]*(.*)$ ]]; then
            key="${BASH_REMATCH[1]}"
            val="${BASH_REMATCH[2]}"
            val="${val%\"}"; val="${val#\"}"
            val="${val%\'}"; val="${val#\'}"
            case "$key" in
                XUI_PANEL_PORT) PANEL_PORT="$val" ;;
                XUI_BASE_PATH) BASE_PATH="$val" ;;
            esac
        fi
    done < "$CRED_FILE"
}

save_credentials(){
    install -d -m 700 /etc/x-ui
    {
        printf "XUI_USERNAME='%s'\n" "$USERNAME"
        printf "XUI_PASSWORD='%s'\n" "$PASSWORD"
        printf "XUI_PANEL_PORT='%s'\n" "$PANEL_PORT"
        printf "XUI_BASE_PATH='%s'\n" "$BASE_PATH"
    } > "$CRED_FILE"
    chmod 600 "$CRED_FILE"
    ok "自定义凭据已保存至 $CRED_FILE（仅 root 可读）。"
}

# 启动时统一询问新账号密码。
prompt_custom_credentials(){
    echo
    echo "=============================================="
    echo " 3x-ui 自定义登录账号设置"
    echo "=============================================="
    echo "接下来会将该账号密码设置为 3x-ui 面板登录凭据。"
    echo "请使用强密码；修改后旧的登录会话可能失效。"
    echo

    while :; do
        read -r -p "请输入自定义用户名：" USERNAME
        if [[ "$USERNAME" =~ ^[a-zA-Z0-9_.@-]{3,64}$ ]]; then
            break
        fi
        warn "用户名需为 3–64 位字母、数字、下划线、点、@ 或连字符。"
    done

    while :; do
        read -r -s -p "请输入自定义密码（至少 12 位）：" PASSWORD
        echo
        if ((${#PASSWORD} < 12)); then
            warn "密码太短，请至少使用 12 位。"
            continue
        fi
        read -r -s -p "请再次输入密码：" password2
        echo
        if [[ "$PASSWORD" == "$password2" ]]; then
            unset password2
            break
        fi
        warn "两次输入不一致，请重试。"
    done
}

# 判断是否存在可用的 3x-ui 管理命令。
find_xui(){
    if command -v x-ui >/dev/null 2>&1; then
        command -v x-ui
        return 0
    fi
    if [[ -x /usr/local/x-ui/x-ui ]]; then
        echo "/usr/local/x-ui/x-ui"
        return 0
    fi
    return 1
}

install_xui_if_needed(){
    if find_xui >/dev/null 2>&1; then
        ok "检测到本机已安装 3x-ui。"
        return 0
    fi

    warn "未检测到 x-ui 管理命令。"
    echo "如果要安装 3x-ui，将调用官方安装脚本。"
    echo "安装程序可能会交互式询问配置；请按提示完成安装。"
    read -r -p "现在安装 3x-ui？输入 YES 确认：" confirm
    if [[ "$confirm" != "YES" ]]; then
        err "未安装 3x-ui，无法继续管理节点。"
        exit 1
    fi

    info "正在下载并启动官方安装程序……"
    if ! bash -c "$(curl -fsSL --connect-timeout 10 --max-time 180 "$INSTALL_URL")"; then
        err "官方安装程序执行失败，请检查网络和安装日志。"
        exit 1
    fi

    if ! find_xui >/dev/null 2>&1; then
        err "安装程序结束后仍未找到 x-ui 命令。"
        echo "请检查安装结果，然后重新运行本脚本。"
        exit 1
    fi
    ok "检测到 3x-ui 管理命令。"
}

apply_custom_credentials(){
    local xui_cmd
    xui_cmd="$(find_xui)" || {
        err "找不到 x-ui 命令。"
        return 1
    }

    info "正在设置自定义面板账号密码……"
    # 只调用 3x-ui 自带设置命令；不直接修改数据库。
    if ! "$xui_cmd" setting -username "$USERNAME" -password "$PASSWORD"; then
        err "3x-ui 修改账号密码失败。"
        echo "请运行 x-ui 查看管理菜单，并检查当前版本支持的命令。"
        return 1
    fi

    save_credentials

    # 读取官方安装结果中的端口和 Base Path。
    load_install_result
    load_saved_config

    # 如果能从 x-ui settings 输出识别端口/路径，则采用输出值。
    local settings_out
    settings_out="$("$xui_cmd" settings 2>&1 || true)"
    local detected
    detected="$(printf '%s\n' "$settings_out" | grep -Eo 'https?://[^[:space:]]+' | head -1 || true)"

    if [[ -n "$detected" ]]; then
        local url_no_scheme
        url_no_scheme="${detected#*://}"
        local hostport="${url_no_scheme%%/*}"
        local pathpart="/${url_no_scheme#*/}"
        if [[ "$hostport" =~ :([0-9]+)$ ]]; then
            PANEL_PORT="${BASH_REMATCH[1]}"
        fi
        if [[ "$pathpart" != "/$url_no_scheme" && "$pathpart" != "/" ]]; then
            BASE_PATH="$pathpart"
            [[ "$BASE_PATH" == */ ]] || BASE_PATH="${BASE_PATH}/"
        fi
    fi

    # 如果管理命令更改凭据后需要重启，重启服务以应用设置。
    if command -v systemctl >/dev/null 2>&1; then
        systemctl restart x-ui || warn "x-ui 重启命令未成功，请检查服务状态。"
    else
        service x-ui restart || warn "x-ui 重启命令未成功，请检查服务状态。"
    fi

    sleep 2
    save_credentials
    ok "自定义账号密码设置流程已完成。"
}

# ---------- API 登录 ----------

setup_urls(){
    load_install_result
    load_saved_config

    [[ "$PANEL_PORT" =~ ^[0-9]{1,5}$ ]] || PANEL_PORT="22682"
    [[ "$BASE_PATH" == /* ]] || BASE_PATH="/$BASE_PATH"
    [[ "$BASE_PATH" == */ ]] || BASE_PATH="${BASE_PATH}/"

    PANEL_ROOT="http://127.0.0.1:${PANEL_PORT}${BASE_PATH%/}"
    LOGIN_URL="${PANEL_ROOT}/login"
    CSRF_URL="${PANEL_ROOT}/csrf-token"
    API_PREFIX="${PANEL_ROOT}/panel/api"
}

http_request(){
    local method="$1" url="$2"
    shift 2
    curl -sS --connect-timeout 4 --max-time 25 \
        -X "$method" -b "$COOKIE" -c "$COOKIE" \
        -o "$BODY" -w '%{http_code}' \
        "$url" "$@" 2>"$WORK/curl-error.txt" || true
}

json_field(){
    python3 - "$BODY" "$1" <<'PY'
import json,sys
try:
    obj=json.load(open(sys.argv[1],encoding="utf-8"))
    for p in sys.argv[2].split("."):
        obj=obj.get(p) if isinstance(obj,dict) else None
    if obj is not None:
        print(str(obj))
except Exception:
    pass
PY
}

api_login(){
    setup_urls
    LOGIN_OK=0
    : > "$COOKIE"

    info "面板端口：$PANEL_PORT"
    info "Base Path：$BASE_PATH"

    info "正在获取 CSRF Token……"
    local status
    status="$(http_request GET "$CSRF_URL" -H 'Accept: application/json')"

    if [[ "$status" != "200" ]]; then
        err "获取 CSRF Token 失败，HTTP：$status"
        cat "$BODY"
        return 1
    fi

    CSRF_TOKEN="$(json_field obj)"
    if [[ -z "$CSRF_TOKEN" || "$CSRF_TOKEN" == "None" ]]; then
        err "未获取到 CSRF Token。"
        cat "$BODY"
        return 1
    fi
    ok "CSRF Token 获取成功。"

    python3 - "$JSON_FILE" "$USERNAME" "$PASSWORD" <<'PY'
import json,sys
with open(sys.argv[1],"w",encoding="utf-8") as f:
    json.dump({"username":sys.argv[2],"password":sys.argv[3]},f)
PY
    chmod 600 "$JSON_FILE"

    info "正在提交登录请求……"
    status="$(http_request POST "$LOGIN_URL" \
        -H 'Content-Type: application/json' \
        -H 'Accept: application/json' \
        -H "X-CSRF-Token: $CSRF_TOKEN" \
        --data-binary "@$JSON_FILE")"

    if [[ "$status" == "200" ]] &&
       [[ "$(json_field success)" == "True" || "$(json_field success)" == "true" ]]; then
        LOGIN_OK=1
        ok "面板登录成功。"
        return 0
    fi

    err "面板登录失败，HTTP：$status"
    echo "返回信息：$(json_field msg)"
    echo "如果启用了 2FA，请检查是否需要额外验证码。"
    echo "如账号密码设置成功但仍无法登录，请运行 x-ui 检查当前设置。"
    cat "$BODY"
    return 1
}

api_get(){
    local path="$1" status
    status="$(http_request GET "${API_PREFIX}${path}" \
        -H 'Accept: application/json' \
        -H "X-CSRF-Token: $CSRF_TOKEN")"

    if [[ "$status" != "200" ]]; then
        err "API 请求失败，HTTP：$status"
        cat "$BODY"
        return 1
    fi
    if [[ "$(json_field success)" == "False" || "$(json_field success)" == "false" ]]; then
        err "API 返回失败："
        cat "$BODY"
        return 1
    fi
}

api_post_file(){
    local path="$1" file="$2" status
    status="$(http_request POST "${API_PREFIX}${path}" \
        -H 'Content-Type: application/json' \
        -H 'Accept: application/json' \
        -H "X-CSRF-Token: $CSRF_TOKEN" \
        --data-binary "@$file")"

    if [[ "$status" != "200" ]] ||
       [[ "$(json_field success)" != "True" && "$(json_field success)" != "true" ]]; then
        err "API 请求失败，HTTP：$status"
        cat "$BODY"
        return 1
    fi
}

list_inbounds(){
    api_login || return 1
    info "正在读取节点列表……"
    api_get "/inbounds/list" || return 1

    python3 - "$BODY" <<'PY'
import json,sys
try:
    obj=json.load(open(sys.argv[1],encoding="utf-8"))
    rows=obj.get("obj") or []
    if isinstance(rows,dict):
        rows=rows.get("inbounds") or []
    if not rows:
        print("当前没有节点。")
    for x in rows:
        print("-"*48)
        print("ID：",x.get("id"))
        print("备注：",x.get("remark"))
        print("协议：",x.get("protocol"))
        print("端口：",x.get("port"))
        print("启用：",x.get("enable"))
except Exception as e:
    print("解析失败：",e)
PY
}

# ---------- 创建 REALITY 入站 ----------

create_reality(){
    api_login || return 1

    command -v xray >/dev/null 2>&1 || {
        err "找不到 xray 命令。"
        return 1
    }

    local remark port dest sni flow uuid sid keyout private_key public_key
    read -r -p "节点备注 [XT-Reality]：" remark
    remark="${remark:-XT-Reality}"

    read -r -p "监听端口（回车随机）：" port
    if [[ -z "$port" ]]; then
        port="$(python3 - <<'PY'
import socket
for p in range(20000,60000):
    s=socket.socket()
    try:
        s.bind(("0.0.0.0",p))
        print(p)
        s.close()
        break
    except OSError:
        s.close()
PY
)"
    fi
    [[ "$port" =~ ^[0-9]+$ ]] && ((port > 0 && port < 65536)) || {
        err "端口不合法。"
        return 1
    }

    read -r -p "REALITY 目标域名 [www.microsoft.com]：" dest
    dest="${dest:-www.microsoft.com}"
    dest="${dest#https://}"
    dest="${dest#http://}"
    dest="${dest%/}"
    [[ "$dest" == *:* ]] || dest="${dest}:443"

    sni="${dest%:*}"
    read -r -p "ServerName [$sni]：" input_sni
    sni="${input_sni:-$sni}"

    read -r -p "Flow [xtls-rprx-vision]：" flow
    flow="${flow:-xtls-rprx-vision}"

    uuid="$(python3 -c 'import uuid; print(uuid.uuid4())')"
    sid="$(python3 -c 'import secrets; print(secrets.token_hex(8))')"

    keyout="$(xray x25519 2>&1)" || {
        err "生成 REALITY 密钥失败。"
        echo "$keyout"
        return 1
    }

    private_key="$(printf '%s\n' "$keyout" | sed -nE 's/^[[:space:]]*PrivateKey:[[:space:]]*(.*)$/\1/p' | head -1)"
    public_key="$(printf '%s\n' "$keyout" | sed -nE 's/^[[:space:]]*(Password|PublicKey):[[:space:]]*(.*)$/\2/p' | head -1)"

    if [[ -z "$private_key" || -z "$public_key" ]]; then
        err "无法识别 xray x25519 的密钥输出格式。"
        echo "$keyout"
        return 1
    fi

    python3 - "$JSON_FILE" "$remark" "$port" "$dest" "$sni" "$flow" "$uuid" "$sid" "$private_key" "$public_key" <<'PY'
import json,sys
_,file,remark,port,dest,sni,flow,uuid,sid,priv,pub=sys.argv
data={
 "enable":True,
 "remark":remark,
 "listen":"",
 "port":int(port),
 "protocol":"vless",
 "settings":{
   "clients":[{"id":uuid,"email":remark,"enable":True,"flow":flow}],
   "decryption":"none",
   "fallbacks":[]
 },
 "streamSettings":{
   "network":"tcp",
   "security":"reality",
   "realitySettings":{
     "show":False,
     "xver":0,
     "dest":dest,
     "serverNames":[sni],
     "privateKey":priv,
     "shortIds":[sid],
     "settings":{
       "publicKey":pub,
       "fingerprint":"chrome",
       "serverName":"",
       "spiderX":"/"
     }
   }
 },
 "sniffing":{"enabled":True,"destOverride":["http","tls","quic"]},
 "allocate":{"strategy":"always","refresh":5,"concurrency":3}
}
with open(file,"w",encoding="utf-8") as f:
    json.dump(data,f,ensure_ascii=False)
PY
    chmod 600 "$JSON_FILE"

    info "正在创建 VLESS + REALITY 入站……"
    api_post_file "/inbounds/add" "$JSON_FILE" || return 1

    ok "已提交节点创建请求。"
    echo
    echo "备注：$remark"
    echo "端口：$port"
    echo "UUID：$uuid"
    echo "目标：$dest"
    echo "ServerName：$sni"
    echo "Short ID：$sid"
    echo "Public Key：$public_key"
    echo
    echo "VLESS 分享链接："
    echo "vless://${uuid}@YOUR_SERVER_IP:${port}?type=tcp&security=reality&encryption=none&pb=${public_key}&fp=chrome&sni=${sni}&sid=${sid}&flow=${flow}#${remark}"
    warn "请将 YOUR_SERVER_IP 替换为 VPS 公网 IPv4，并在防火墙/安全组放行 TCP 端口。"
}

show_status(){
    echo "===== x-ui 状态 ====="
    if command -v systemctl >/dev/null 2>&1; then
        systemctl --no-pager --full status x-ui 2>&1 | head -40 || true
    else
        service x-ui status 2>&1 || true
    fi

    echo
    echo "===== 监听端口 ====="
    if command -v ss >/dev/null 2>&1; then
        ss -lntp 2>/dev/null | grep -E ":(${PANEL_PORT}|2096)\\b" || true
    fi

    echo
    echo "===== 最近 50 行日志 ====="
    if command -v journalctl >/dev/null 2>&1; then
        journalctl -u x-ui -n 50 --no-pager 2>&1 || true
    fi
}

restart_xui(){
    read -r -p "重启会短暂中断服务。输入 YES 确认：" confirm
    [[ "$confirm" == "YES" ]] || {
        info "已取消。"
        return
    }

    if command -v systemctl >/dev/null 2>&1; then
        systemctl restart x-ui
    else
        service x-ui restart
    fi
    sleep 2
    ok "已发送重启命令。"
}

menu(){
    while true; do
        echo
        echo "=============================================="
        echo " $APP_NAME"
        echo "=============================================="
        echo "1. 检查面板配置"
        echo "2. 测试登录并列出节点"
        echo "3. 创建 VLESS + REALITY 节点"
        echo "4. 查看服务状态和日志"
        echo "5. 重启 x-ui"
        echo "0. 退出"
        echo "=============================================="
        read -r -p "请选择：" choice

        case "$choice" in
            1)
                setup_urls
                echo "面板端口：$PANEL_PORT"
                echo "Base Path：$BASE_PATH"
                echo "用户名：$USERNAME"
                echo "凭据文件：$CRED_FILE"
                echo "数据库文件：$DB"
                echo "不会自动输出密码。"
                pause
                ;;
            2)
                list_inbounds
                pause
                ;;
            3)
                create_reality
                pause
                ;;
            4)
                setup_urls
                show_status
                pause
                ;;
            5)
                restart_xui
                pause
                ;;
            0)
                echo "已退出。"
                break
                ;;
            *)
                warn "无效选项。"
                ;;
        esac
    done
}

# ---------- 主程序 ----------

need_root
need_dependencies

# 1. 先让用户设置自定义账号密码。
prompt_custom_credentials

# 2. 检测或安装 3x-ui。
install_xui_if_needed

# 3. 设置账号密码；不直接操作数据库。
if ! apply_custom_credentials; then
    err "账号密码自动设置未完成，停止后续 API 操作。"
    echo "请执行 x-ui 检查管理菜单和当前版本支持的设置命令。"
    exit 1
fi

# 4. 继续进入原有节点管理菜单。
setup_urls
menu
