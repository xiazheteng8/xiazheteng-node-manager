
#!/usr/bin/env bash
# ============================================================
# 瞎折腾吧 | 3x-ui 节点管理器
# 功能：自动识别配置、CSRF 登录、列出节点、创建 REALITY 节点
#       查看日志、重启 x-ui
# 数据库：只读读取配置，不删除或重建数据库
# ============================================================

set -uo pipefail
umask 077

APP_NAME="瞎折腾吧 | 3x-ui 节点管理器"
DB="/etc/x-ui/x-ui.db"
CONFIG_FILE="/etc/x-ui/node-manager.env"
WORK="/tmp/xui-node-manager-$$"
COOKIE="$WORK/cookies.txt"
BODY="$WORK/response.json"
LOGIN_JSON="$WORK/login.json"
INBOUND_JSON="$WORK/inbound.json"

PANEL_PORT="22682"
BASE_PATH=""
PANEL_ORIGIN=""
PANEL_ROOT=""
LOGIN_URL=""
CSRF_URL=""
API_PREFIX=""
USERNAME=""
PASSWORD=""
CSRF_TOKEN=""
LOGIN_OK=0

mkdir -p "$WORK"
chmod 700 "$WORK"
touch "$COOKIE" "$BODY"
trap 'rm -rf "$WORK"' EXIT

# ---------- 基础工具 ----------

info() { printf '\033[36m[信息]\033[0m %s\n' "$*"; }
ok()   { printf '\033[32m[成功]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[提示]\033[0m %s\n' "$*"; }
err()  { printf '\033[31m[错误]\033[0m %s\n' "$*" >&2; }

pause() {
    echo
    read -r -p "按回车键继续……" _
}

need_commands() {
    local missing=()
    for c in curl python3; do
        command -v "$c" >/dev/null 2>&1 || missing+=("$c")
    done

    if ((${#missing[@]})); then
        err "缺少依赖：${missing[*]}"
        echo "Debian/Ubuntu 可执行：apt-get update && apt-get install -y curl python3"
        return 1
    fi
    return 0
}

json_get() {
    # 用法：json_get 文件 字段
    python3 - "$1" "$2" <<'PY'
import json,sys
try:
    with open(sys.argv[1], encoding="utf-8") as f:
        obj=json.load(f)
    value=obj
    for part in sys.argv[2].split("."):
        if isinstance(value, dict):
            value=value.get(part)
        else:
            value=None
            break
    if isinstance(value, (dict,list)):
        print(json.dumps(value, ensure_ascii=False))
    elif value is not None:
        print(value)
except Exception:
    pass
PY
}

is_true_json() {
    [[ "$(json_get "$1" success)" == "True" ||
       "$(json_get "$1" success)" == "true" ]]
}

valid_base_path() {
    local p="$1"
    [[ "$p" == /* ]] || p="/$p"
    [[ "$p" == */ ]] || p="$p/"
    printf '%s' "$p"
}

# ---------- 从数据库只读发现配置 ----------
# 仅读取 settings 表中的键值配置。
# 不会将 users 表里的密码哈希当成明文密码。

read_db_settings() {
    [[ -f "$DB" ]] || return 0

    python3 - "$DB" <<'PY'
import sqlite3,sys
db=sys.argv[1]
try:
    uri="file:"+db+"?mode=ro"
    con=sqlite3.connect(uri, uri=True, timeout=3)
    tables={r[0] for r in con.execute(
        "SELECT name FROM sqlite_master WHERE type='table'"
    )}
    if "settings" not in tables:
        sys.exit(0)

    cols=[r[1] for r in con.execute("PRAGMA table_info(settings)")]
    lower={c.lower():c for c in cols}
    keycol=next((lower[k] for k in ("key","name","setting") if k in lower),None)
    valcol=next((lower[k] for k in ("value","val","setting_value") if k in lower),None)
    if not keycol or not valcol:
        sys.exit(0)

    rows=con.execute(
        'SELECT "'+keycol+'","'+valcol+'" FROM settings'
    ).fetchall()

    wanted={
        "webuser":"username", "webusername":"username",
        "username":"username", "web_user":"username",
        "webpass":"password", "webpassword":"password",
        "password":"password", "web_pass":"password",
        "webport":"port", "web_port":"port",
        "webbasepath":"basepath", "web_base_path":"basepath",
        "webpath":"basepath", "web_path":"basepath",
    }
    result={}
    for k,v in rows:
        if k is None or v is None:
            continue
        norm=str(k).strip().lower()
        dest=wanted.get(norm)
        if dest and str(v).strip():
            result[dest]=str(v).strip()

    # 只输出端口、路径和用户名；绝不输出密码。
    for k in ("port","basepath","username"):
        if result.get(k):
            print(k+"="+result[k])

    # 仅在本机 settings 明确保存了疑似明文值时输出给父进程。
    # 哈希形式的值一律跳过。
    pw=result.get("password","")
    if pw:
        low=pw.lower()
        hashed=(
            pw.startswith(("$2a$","$2b$","$2y$","$argon2","$scrypt$")) or
            low.startswith(("pbkdf2:","sha256:","sha512:")) or
            len(pw) >= 60 and all(c.isalnum() or c in "./$" for c in pw)
        )
        if not hashed:
            # Base64 编码的多行内容也不适合作为密码自动提交。
            if "\n" not in pw and "\r" not in pw:
                print("password="+pw)

    con.close()
except Exception:
    pass
PY
}

# ---------- 可选凭据文件 ----------
# 如需自行保存凭据，可建立：
# /etc/x-ui/node-manager.env
# 内容格式：
# XUI_USERNAME='你的用户名'
# XUI_PASSWORD='你的密码'
# XUI_PANEL_PORT='22682'
# XUI_BASE_PATH='/你的BasePath/'
#
# 文件权限必须为 600。脚本不会创建或覆盖这个文件。

read_env_config() {
    local f="$1"
    [[ -f "$f" ]] || return 0

    if [[ "$(stat -c '%a' "$f" 2>/dev/null || echo 777)" != "600" ]]; then
        warn "凭据文件 $f 权限不是 600，跳过读取以避免泄露。"
        return 0
    fi

    # 不 source 外部脚本；只读取简单 KEY=VALUE 行。
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        [[ "$line" =~ ^[[:space:]]*# || -z "$line" ]] && continue
        if [[ "$line" =~ ^[[:space:]]*(XUI_USERNAME|XUI_PASSWORD|XUI_PANEL_PORT|XUI_BASE_PATH)[[:space:]]*=[[:space:]]*(.*)$ ]]; then
            local key="${BASH_REMATCH[1]}"
            local val="${BASH_REMATCH[2]}"
            val="${val%\"}"; val="${val#\"}"
            val="${val%\'}"; val="${val#\'}"
            case "$key" in
                XUI_USERNAME) [[ -n "$USERNAME" ]] || USERNAME="$val" ;;
                XUI_PASSWORD) [[ -n "$PASSWORD" ]] || PASSWORD="$val" ;;
                XUI_PANEL_PORT) [[ "$PANEL_PORT" != "22682" ]] || PANEL_PORT="$val" ;;
                XUI_BASE_PATH) [[ -n "$BASE_PATH" ]] || BASE_PATH="$val" ;;
            esac
        fi
    done < "$f"
}

discover_config() {
    info "正在识别 3x-ui 配置……"

    local dbout
    dbout="$(read_db_settings 2>/dev/null || true)"

    while IFS='=' read -r key val; do
        case "$key" in
            port) [[ "$PANEL_PORT" != "22682" ]] || PANEL_PORT="$val" ;;
            basepath) [[ -n "$BASE_PATH" ]] || BASE_PATH="$val" ;;
            username) [[ -n "$USERNAME" ]] || USERNAME="$val" ;;
            password) [[ -n "$PASSWORD" ]] || PASSWORD="$val" ;;
        esac
    done <<< "$dbout"

    read_env_config "$CONFIG_FILE"
    read_env_config "/root/.config/x-ui-node-manager.env"
    read_env_config "/root/.x-ui-credentials"

    # 默认尝试从 3x-ui 数据库设置中读取 Base Path/端口；
    # 如果没有取到，使用本次已知环境的端口与路径。
    [[ "$PANEL_PORT" =~ ^[0-9]{1,5}$ ]] || PANEL_PORT="22682"
    [[ -n "$BASE_PATH" ]] || BASE_PATH="/DzFtThyY0rcdykt4CC/"
    BASE_PATH="$(valid_base_path "$BASE_PATH")"

    PANEL_ORIGIN="http://127.0.0.1:${PANEL_PORT}"
    PANEL_ROOT="${PANEL_ORIGIN}${BASE_PATH%/}"
    LOGIN_URL="${PANEL_ROOT}/login"
    CSRF_URL="${PANEL_ROOT}/csrf-token"
    API_PREFIX="${PANEL_ROOT}/panel/api"

    echo "面板端口：$PANEL_PORT"
    echo "Base Path：$BASE_PATH"
    echo "用户名：$([[ -n "$USERNAME" ]] && echo "已识别（$USERNAME）" || echo "未识别")"
    echo "密码：$([[ -n "$PASSWORD" ]] && echo "检测到可尝试的本机凭据" || echo "未发现可直接使用的明文密码")"
}

# ---------- HTTP 请求 ----------
# HTTP 状态码写入标准输出；响应体写入 BODY。
request() {
    local method="$1"
    local url="$2"
    shift 2

    curl -sS --connect-timeout 4 --max-time 25 \
        -X "$method" \
        -b "$COOKIE" -c "$COOKIE" \
        -o "$BODY" -w '%{http_code}' \
        "$url" "$@" 2>"$WORK/curl-error.txt" || true
}

get_csrf() {
    info "正在获取 CSRF Token……"

    local status
    status="$(request GET "$CSRF_URL" -H 'Accept: application/json')"

    if [[ "$status" != "200" ]]; then
        err "获取 CSRF Token 失败，HTTP：$status"
        cat "$WORK/curl-error.txt" 2>/dev/null
        [[ -s "$BODY" ]] && cat "$BODY"
        return 1
    fi

    CSRF_TOKEN="$(json_get "$BODY" obj)"
    if [[ -z "$CSRF_TOKEN" || "$CSRF_TOKEN" == "null" ]]; then
        err "响应中没有 CSRF Token。请检查 Base Path、端口和面板状态。"
        cat "$BODY"
        return 1
    fi

    ok "CSRF Token 获取成功。"
    return 0
}

api_login() {
    LOGIN_OK=0
    discover_config

    if [[ -z "$USERNAME" ]]; then
        read -r -p "3x-ui 用户名：" USERNAME
    fi

    if [[ -z "$PASSWORD" ]]; then
        read -r -s -p "3x-ui 密码：" PASSWORD
        echo
    else
        info "将尝试本机已识别的凭据。"
    fi

    if [[ -z "$USERNAME" || -z "$PASSWORD" ]]; then
        err "用户名或密码为空。"
        return 1
    fi

    # 每次登录使用新的 Cookie 文件，避免旧会话干扰。
    : > "$COOKIE"

    get_csrf || return 1

    python3 - "$LOGIN_JSON" "$USERNAME" "$PASSWORD" <<'PY'
import json,sys
with open(sys.argv[1],"w",encoding="utf-8") as f:
    json.dump({"username":sys.argv[2],"password":sys.argv[3]},f)
PY
    chmod 600 "$LOGIN_JSON"

    info "正在提交登录请求……"
    local status
    status="$(request POST "$LOGIN_URL" \
        -H 'Content-Type: application/json' \
        -H 'Accept: application/json' \
        -H "X-CSRF-Token: $CSRF_TOKEN" \
        --data-binary "@$LOGIN_JSON")"

    if [[ "$status" == "200" ]] && is_true_json "$BODY"; then
        LOGIN_OK=1
        ok "面板登录成功。"
        return 0
    fi

    err "面板登录失败，HTTP：$status"
    local msg
    msg="$(json_get "$BODY" msg)"
    [[ -n "$msg" && "$msg" != "null" ]] && echo "原因：$msg"

    if grep -qiE 'Invalid username or password|Wrong username or password' "$BODY"; then
        echo
        warn "本机识别到的凭据不是可用的登录凭据，或面板启用了双重验证。"
        echo "数据库中的密码哈希无法反向还原为原始密码。"
        echo "请通过 x-ui 官方管理菜单查看/重置面板登录凭据后再运行脚本。"
    elif [[ "$status" == "403" ]]; then
        warn "HTTP 403：检查 Base Path、CSRF Token、访问策略或认证机制。"
    fi

    [[ -s "$BODY" ]] && cat "$BODY"
    return 1
}

api_get() {
    local path="$1"
    [[ "$LOGIN_OK" == "1" ]] || { err "尚未登录。"; return 1; }

    local status
    status="$(request GET "${API_PREFIX}${path}" \
        -H 'Accept: application/json' \
        -H "X-CSRF-Token: $CSRF_TOKEN")

    if [[ "$status" != "200" ]]; then
        err "API 请求失败，HTTP：$status"
        [[ -s "$BODY" ]] && cat "$BODY"
        return 1
    fi

    if grep -q '"success"[[:space:]]*:[[:space:]]*false' "$BODY"; then
        err "API 返回失败："
        cat "$BODY"
        return 1
    fi
    return 0
}

api_post_file() {
    local path="$1"
    local json_file="$2"
    [[ "$LOGIN_OK" == "1" ]] || { err "尚未登录。"; return 1; }

    local status
    status="$(request POST "${API_PREFIX}${path}" \
        -H 'Content-Type: application/json' \
        -H 'Accept: application/json' \
        -H "X-CSRF-Token: $CSRF_TOKEN" \
        --data-binary "@$json_file")

    if [[ "$status" != "200" ]]; then
        err "API 请求失败，HTTP：$status"
        [[ -s "$BODY" ]] && cat "$BODY"
        return 1
    fi

    if ! is_true_json "$BODY"; then
        err "API 返回失败："
        cat "$BODY"
        return 1
    fi
    return 0
}

# ---------- 节点列表 ----------

list_inbounds() {
    if [[ "$LOGIN_OK" != "1" ]]; then
        api_login || return 1
    fi

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
        print("当前没有可显示的节点。")
    for x in rows:
        print("-"*54)
        print("ID：",x.get("id",""))
        print("备注：",x.get("remark",""))
        print("协议：",x.get("protocol",""))
        print("端口：",x.get("port",""))
        print("启用：",x.get("enable",""))
        print("流量上限：",x.get("total",""))
        print("到期时间：",x.get("expiryTime",""))
        stream=x.get("streamSettings") or {}
        reality=stream.get("realitySettings") or {}
        print("传输：",stream.get("network",""))
        print("安全：",stream.get("security",""))
        print("目标：",reality.get("dest",""))
except Exception as e:
    print("解析节点列表失败：",e)
    print(open(sys.argv[1],encoding="utf-8").read())
PY
}

# ---------- 创建 VLESS + REALITY ----------

get_random_port() {
    python3 <<'PY'
import socket
for port in range(20000,60000):
    s=socket.socket()
    try:
        s.bind(("0.0.0.0",port))
        print(port)
        s.close()
        break
    except OSError:
        s.close()
PY
}

generate_reality_keys() {
    local output
    command -v xray >/dev/null 2>&1 || {
        err "未找到 xray 命令，无法生成 REALITY 密钥。"
        return 1
    }

    output="$(xray x25519 2>&1 || true)"
    local priv pub
    priv="$(printf '%s\n' "$output" | sed -nE 's/^[[:space:]]*PrivateKey:[[:space:]]*(.*)$/\1/p' | head -1)"
    pub="$(printf '%s\n' "$output" | sed -nE 's/^[[:space:]]*(Password|PublicKey):[[:space:]]*(.*)$/\2/p' | head -1)"

    if [[ -z "$priv" || -z "$pub" ]]; then
        echo "$output"
        err "无法识别 xray x25519 密钥输出格式。"
        return 1
    fi

    printf '%s\n%s\n' "$priv" "$pub"
}

create_reality_inbound() {
    api_login || return 1

    local remark port dest server_name flow uuid short_id keys private_key public_key
    read -r -p "节点备注 [XT-Reality]：" remark
    remark="${remark:-XT-Reality}"

    read -r -p "监听端口（回车自动选择）：" port
    if [[ -z "$port" ]]; then
        port="$(get_random_port)"
    fi
    if [[ ! "$port" =~ ^[0-9]+$ ]] || ((port < 1 || port > 65535)); then
        err "端口不合法。"
        return 1
    fi

    read -r -p "REALITY 目标域名 [www.microsoft.com]：" dest
    dest="${dest:-www.microsoft.com}"
    dest="${dest#https://}"
    dest="${dest#http://}"
    dest="${dest%/}"
    [[ "$dest" == *:* ]] || dest="${dest}:443"

    server_name="${dest%:*}"
    read -r -p "ServerName [$server_name]：" flow
    server_name="${flow:-$server_name}"

    read -r -p "客户端 Flow [xtls-rprx-vision]：" flow
    flow="${flow:-xtls-rprx-vision}"

    uuid="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || true)"
    if [[ -z "$uuid" ]]; then
        uuid="$(python3 -c 'import uuid; print(uuid.uuid4())')"
    fi

    short_id="$(openssl rand -hex 8 2>/dev/null || true)"
    if [[ -z "$short_id" ]]; then
        short_id="$(python3 -c 'import secrets; print(secrets.token_hex(8))')"
    fi

    info "正在生成 REALITY 密钥……"
    keys="$(generate_reality_keys)" || return 1
    private_key="$(printf '%s\n' "$keys" | sed -n '1p')"
    public_key="$(printf '%s\n' "$keys" | sed -n '2p')"

    python3 - "$INBOUND_JSON" "$remark" "$port" "$dest" "$server_name" \
        "$flow" "$uuid" "$short_id" "$private_key" <<'PY'
import json,sys
_,path,remark,port,dest,sni,flow,uuid,sid,priv=sys.argv
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
     "settings":{"publicKey":"","fingerprint":"chrome","serverName":"","spiderX":"/"}
   }
 },
 "sniffing":{
   "enabled":True,
   "destOverride":["http","tls","quic"]
 },
 "allocate":{"strategy":"always","refresh":5,"concurrency":3}
}
with open(path,"w",encoding="utf-8") as f:
    json.dump(data,f,ensure_ascii=False)
PY
    chmod 600 "$INBOUND_JSON"

    info "正在创建 VLESS + REALITY 入站……"
    if ! api_post_file "/inbounds/add" "$INBOUND_JSON"; then
        err "创建失败。没有删除或覆盖现有节点。"
        return 1
    fi

    ok "节点已提交创建请求。"
    echo
    echo "备注：$remark"
    echo "端口：$port"
    echo "UUID：$uuid"
    echo "目标：$dest"
    echo "ServerName：$server_name"
    echo "Short ID：$short_id"
    echo "Public Key：$public_key"
    echo
    warn "请确认当前 3x-ui/Xray 版本接受该 REALITY 配置，并在防火墙/安全组放行 TCP $port。"
    warn "如果面板返回的节点配置中没有保存 Public Key，请在面板中检查该入站的 REALITY 设置。"

    # 尝试输出客户端 URI。公钥使用 xray x25519 输出中的 Password/PublicKey。
    local encoded_remark
    encoded_remark="$(python3 - "$remark" <<'PY'
import sys,urllib.parse
print(urllib.parse.quote(sys.argv[1],safe=""))
PY
)"
    echo "VLESS 分享链接："
    echo "vless://${uuid}@YOUR_SERVER_IP:${port}?type=tcp&security=reality&encryption=none&pbk=${public_key}&fp=chrome&sni=${server_name}&sid=${short_id}&flow=${flow}#${encoded_remark}"
    echo
    warn "将 YOUR_SERVER_IP 替换成 VPS 公网 IPv4；请确认端口已开放。"
}

# ---------- 服务状态与日志 ----------

show_status_logs() {
    echo "===== x-ui 服务状态 ====="
    if command -v systemctl >/dev/null 2>&1; then
        systemctl --no-pager --full status x-ui 2>&1 | head -45
    else
        service x-ui status 2>&1 || true
    fi

    echo
    echo "===== 监听端口 ====="
    if command -v ss >/dev/null 2>&1; then
        ss -lntp 2>/dev/null | grep -E ":(${PANEL_PORT}|2096)\\b" || true
    else
        netstat -lntp 2>/dev/null | grep -E ":(${PANEL_PORT}|2096)\\b" || true
    fi

    echo
    echo "===== 最近 60 行日志 ====="
    if command -v journalctl >/dev/null 2>&1; then
        journalctl -u x-ui -n 60 --no-pager 2>&1 || true
    elif [[ -f /var/log/x-ui.log ]]; then
        tail -60 /var/log/x-ui.log
    else
        warn "未找到可读取的 x-ui 日志。"
    fi
}

restart_xui() {
    echo
    warn "重启 x-ui 会短暂中断面板和相关服务。"
    read -r -p "确定重启？输入 YES 确认：" confirm
    [[ "$confirm" == "YES" ]] || {
        info "已取消。"
        return 0
    }

    if command -v systemctl >/dev/null 2>&1; then
        systemctl restart x-ui || {
            err "重启失败。"
            return 1
        }
    else
        service x-ui restart || {
            err "重启失败。"
            return 1
        }
    fi

    sleep 2
    ok "已发送重启命令。"
    systemctl --no-pager --full status x-ui 2>&1 | head -20 || true
}

check_config() {
    discover_config
    echo
    echo "===== 服务信息 ====="
    systemctl is-active x-ui 2>/dev/null || true
    echo
    echo "===== 本机 HTTP 连通性 ====="
    curl -sS --connect-timeout 3 --max-time 5 \
        -o /dev/null -w "HTTP 状态：%{http_code}\n" \
        "${PANEL_ORIGIN}/" 2>/dev/null || echo "无法连接面板根路径"
    echo
    echo "===== 数据库文件 ====="
    if [[ -r "$DB" ]]; then
        ls -lh "$DB"
    else
        warn "无法读取数据库：$DB"
    fi
    echo
    echo "注意：密码哈希不可逆恢复；脚本不会尝试暴力破解。"
}

# ---------- 主菜单 ----------

main_menu() {
    while true; do
        echo
        echo "=============================================="
        echo "$APP_NAME"
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
                check_config
                pause
                ;;
            2)
                LOGIN_OK=0
                if api_login; then
                    list_inbounds
                fi
                pause
                ;;
            3)
                create_reality_inbound
                pause
                ;;
            4)
                show_status_logs
                pause
                ;;
            5)
                restart_xui
                pause
                ;;
            0)
                echo "已退出。"
                return 0
                ;;
            *)
                warn "无效选项，请重新选择。"
                ;;
        esac
    done
}

# ---------- 启动 ----------

if [[ $EUID -ne 0 ]]; then
    err "请使用 root 运行此脚本。"
    exit 1
fi

need_commands || exit 1

# 初始化已知环境；每次执行菜单时仍会重新发现可读取的配置。
discover_config >/dev/null 2>&1 || true
main_menu
