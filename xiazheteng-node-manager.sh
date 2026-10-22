
#!/usr/bin/env bash
# ============================================================
# 瞎折腾吧 | 3x-ui 节点管理器
# 单文件版：复用已有 3x-ui，保留现有数据库和节点
# 修复：先获取 CSRF Token，再登录；POST 请求携带 CSRF Header
# ============================================================

set -Eeuo pipefail
umask 077

DB="/etc/x-ui/x-ui.db"
WORK="/tmp/xiazheteng-node-manager"
mkdir -p "$WORK"
chmod 700 "$WORK"

COOKIE="$WORK/cookies.txt"
BODY="$WORK/response.json"
LOGIN_JSON="$WORK/login.json"
INBOUND_JSON="$WORK/inbound.json"

RED='\033[31m'; GREEN='\033[32m'; YELLOW='\033[33m'
BLUE='\033[36m'; RESET='\033[0m'

info(){ echo -e "${BLUE}[信息]${RESET} $*"; }
ok(){ echo -e "${GREEN}[成功]${RESET} $*"; }
warn(){ echo -e "${YELLOW}[警告]${RESET} $*"; }
err(){ echo -e "${RED}[错误]${RESET} $*" >&2; }

[[ $EUID -eq 0 ]] || { err "请使用 root 运行。"; exit 1; }

for c in curl python3 openssl sqlite3; do
    command -v "$c" >/dev/null 2>&1 || {
        err "缺少依赖：$c"
        echo "Debian/Ubuntu：apt-get update && apt-get install -y curl python3 openssl sqlite3"
        exit 1
    }
done

# 从 settings 表读取配置；只读访问数据库
db_setting() {
    local key="$1"
    [[ -f "$DB" ]] || return 1

    python3 - "$DB" "$key" <<'PY'
import sqlite3, sys
db, wanted = sys.argv[1:]
aliases = {
    "username": ["username", "webUser", "webUsername"],
    "password": ["password", "webPass", "webPassword"],
    "webPort": ["webPort", "port"],
    "webBasePath": ["webBasePath", "basePath", "webPath"],
}
try:
    con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    tables = [r[0] for r in con.execute(
        "SELECT name FROM sqlite_master WHERE type='table'"
    )]
    for table in tables:
        cols = [r[1] for r in con.execute(f'PRAGMA table_info("{table}")')]
        if "key" in cols and "value" in cols:
            for key in aliases.get(wanted, [wanted]):
                row = con.execute(
                    f'SELECT value FROM "{table}" WHERE key=? LIMIT 1',
                    (key,)
                ).fetchone()
                if row and row[0] is not None and str(row[0]):
                    print(str(row[0]))
                    sys.exit(0)
    con.close()
except Exception:
    pass
sys.exit(1)
PY
}

normalise_path() {
    local p="${1:-/}"
    [[ "$p" == /* ]] || p="/$p"
    [[ "$p" == */ ]] || p="$p/"
    printf '%s' "$p"
}

discover_panel() {
    PANEL_PORT="$(db_setting webPort 2>/dev/null || true)"
    PANEL_BASE="$(db_setting webBasePath 2>/dev/null || true)"
    PANEL_USER="$(db_setting username 2>/dev/null || true)"
    PANEL_PASS="$(db_setting password 2>/dev/null || true)"

    if [[ ! "$PANEL_PORT" =~ ^[0-9]{1,5}$ ]]; then
        err "无法从数据库识别面板端口。请检查 x-ui setting -show。"
        return 1
    fi

    PANEL_BASE="$(normalise_path "${PANEL_BASE:-/}")"
    PANEL_ORIGIN="http://127.0.0.1:${PANEL_PORT}"
    PANEL_ROOT="${PANEL_ORIGIN}${PANEL_BASE%/}"
    LOGIN_URL="${PANEL_ROOT}/login"
    CSRF_URL="${PANEL_ROOT}/csrf-token"
    API_PREFIX="${PANEL_ROOT}/panel/api"

    info "面板端口：$PANEL_PORT"
    info "Base Path：$PANEL_BASE"
}

# 保存服务器返回内容并输出 HTTP 状态码
request() {
    local method="$1" url="$2"
    shift 2
    curl -sS --connect-timeout 4 --max-time 20 \
        -X "$method" -b "$COOKIE" -c "$COOKIE" \
        -o "$BODY" -w '%{http_code}' "$url" "$@" \
        2>"$WORK/curl-error.txt" || true
}

# 从响应 JSON 提取 obj；成功时打印令牌
extract_csrf() {
    python3 - "$BODY" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1], encoding="utf-8"))
    token = d.get("obj")
    if d.get("success") and isinstance(token, str) and token:
        print(token)
        sys.exit(0)
except Exception:
    pass
sys.exit(1)
PY
}

# 统一验证 API JSON 响应中的 success 字段
json_success() {
    python3 - "$BODY" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1], encoding="utf-8"))
    sys.exit(0 if d.get("success") is True else 1)
except Exception:
    sys.exit(1)
PY
}

show_response() {
    python3 - "$BODY" <<'PY'
import sys
try:
    s = open(sys.argv[1], encoding="utf-8", errors="replace").read()
    print(s[:1600] if s else "(空响应)")
except Exception:
    print("(无法读取响应)")
PY
}

# 先获取 CSRF Token，再使用同一 Cookie Jar 登录
api_login() {
    discover_panel || return 1

    if [[ -z "${PANEL_USER:-}" ]]; then
        read -r -p "3x-ui 用户名：" PANEL_USER
    else
        info "已识别用户名字段。"
    fi

    if [[ -z "${PANEL_PASS:-}" ]]; then
        read -r -s -p "3x-ui 密码：" PANEL_PASS
        echo
    else
        info "已识别密码字段。"
    fi

    [[ -n "$PANEL_USER" && -n "$PANEL_PASS" ]] || {
        err "用户名或密码为空。"
        return 1
    }

    : > "$COOKIE"

    info "正在获取 CSRF Token……"
    local status
    status="$(request GET "$CSRF_URL")"

    if [[ "$status" != "200" ]]; then
        err "获取 CSRF Token 失败，HTTP：$status"
        show_response
        [[ -s "$WORK/curl-error.txt" ]] && cat "$WORK/curl-error.txt"
        return 1
    fi

    CSRF_TOKEN="$(extract_csrf)" || {
        err "响应中没有有效 CSRF Token："
        show_response
        return 1
    }

    ok "CSRF Token 获取成功。"

    python3 - "$LOGIN_JSON" "$PANEL_USER" "$PANEL_PASS" <<'PY'
import json, sys
path, user, password = sys.argv[1:]
with open(path, "w", encoding="utf-8") as f:
    json.dump({
        "username": user,
        "password": password
    }, f)
PY
    chmod 600 "$LOGIN_JSON"

    info "正在提交登录请求……"
    status="$(request POST "$LOGIN_URL" \
        -H 'Content-Type: application/json' \
        -H 'Accept: application/json' \
        -H "X-CSRF-Token: $CSRF_TOKEN" \
        --data-binary "@$LOGIN_JSON")"
    rm -f "$LOGIN_JSON"

    if [[ "$status" == "200" ]] && json_success; then
        ok "面板登录成功。"
        return 0
    fi

    err "面板登录失败，HTTP：$status"
    show_response

    if [[ "$status" == "403" ]]; then
        warn "仍然返回 403：请检查登录限流、二步验证和 x-ui 日志。"
        warn "本脚本不会重置密码、修改数据库或反复尝试登录。"
    fi
    return 1
}

# API 的所有 POST 请求都附带当前会话的 CSRF Token
api_post() {
    local endpoint="$1" json_file="$2" status
    status="$(request POST "${API_PREFIX}${endpoint}" \
        -H 'Content-Type: application/json' \
        -H 'Accept: application/json' \
        -H "X-CSRF-Token: $CSRF_TOKEN" \
        --data-binary "@$json_file")"

    if [[ "$status" != "200" ]] || ! json_success; then
        err "API 请求失败：$endpoint，HTTP：$status"
        show_response
        return 1
    fi
    return 0
}

api_get() {
    local endpoint="$1" status
    status="$(request GET "${API_PREFIX}${endpoint}" \
        -H 'Accept: application/json' \
        -H "X-CSRF-Token: $CSRF_TOKEN")"

    if [[ "$status" != "200" ]] || ! json_success; then
        err "API 请求失败：$endpoint，HTTP：$status"
        show_response
        return 1
    fi
    return 0
}

find_xray() {
    local p
    for p in /usr/local/x-ui/bin/xray /usr/local/bin/xray /usr/bin/xray; do
        [[ -x "$p" ]] && { printf '%s' "$p"; return 0; }
    done
    command -v xray 2>/dev/null
}

get_public_ipv4() {
    local ip
    for url in https://api.ipify.org https://ipv4.icanhazip.com; do
        ip="$(curl -4 -fsS --connect-timeout 3 --max-time 5 "$url" 2>/dev/null |
            tr -d '[:space:]' || true)"
        if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
            printf '%s' "$ip"
            return 0
        fi
    done
    return 1
}

random_port() {
    python3 - <<'PY'
import socket, random
for _ in range(200):
    p = random.randint(20000, 60000)
    s = socket.socket()
    try:
        s.bind(("0.0.0.0", p))
        s.close()
        print(p)
        break
    except OSError:
        s.close()
PY
}

generate_reality_keys() {
    local xray="$1" output
    output="$("$xray" x25519 2>&1)" || {
        err "Xray 生成密钥失败："
        printf '%s\n' "$output"
        return 1
    }

    REALITY_PRIVATE_KEY="$(
        printf '%s\n' "$output" |
        sed -nE 's/^[[:space:]]*PrivateKey:[[:space:]]*([^[:space:]]+).*$/\1/p' |
        head -n1
    )"
    REALITY_PUBLIC_KEY="$(
        printf '%s\n' "$output" |
        sed -nE 's/^[[:space:]]*Password:[[:space:]]*([^[:space:]]+).*$/\1/p' |
        head -n1
    )"

    # 兼容输出标签为 Private key / Public key 的版本
    [[ -n "$REALITY_PRIVATE_KEY" ]] || REALITY_PRIVATE_KEY="$(
        printf '%s\n' "$output" |
        sed -nE 's/^[[:space:]]*Private[[:space:]]*key:[[:space:]]*([^[:space:]]+).*$/\1/p' |
        head -n1
    )"
    [[ -n "$REALITY_PUBLIC_KEY" ]] || REALITY_PUBLIC_KEY="$(
        printf '%s\n' "$output" |
        sed -nE 's/^[[:space:]]*(Public[[:space:]]*key|PublicKey):[[:space:]]*([^[:space:]]+).*$/\2/p' |
        head -n1
    )"

    if [[ -z "$REALITY_PRIVATE_KEY" || -z "$REALITY_PUBLIC_KEY" ]]; then
        err "无法识别当前 Xray 的密钥输出格式："
        printf '%s\n' "$output"
        return 1
    fi
}

add_reality_inbound() {
    api_login || return 1

    local xray ip port uuid remark dest sni sid
    xray="$(find_xray)" || { err "未找到 Xray。"; return 1; }

    ip="$(get_public_ipv4 || true)"
    [[ -n "$ip" ]] || read -r -p "请输入服务器公网 IPv4：" ip

    read -r -p "节点备注 [Xiazheteng-REALITY]：" remark
    remark="${remark:-Xiazheteng-REALITY}"

    read -r -p "REALITY 目标域名 [www.microsoft.com]：" dest
    dest="${dest:-www.microsoft.com}"
    sni="${dest%%:*}"

    read -r -p "监听端口（留空自动选择）：" port
    port="${port:-$(random_port)}"

    [[ "$port" =~ ^[0-9]+$ ]] && ((port >= 1 && port <= 65535)) || {
        err "端口无效。"
        return 1
    }

    if ss -lnt 2>/dev/null | awk '{print $4}' |
        grep -Eq "(:|\])${port}$"; then
        err "端口 $port 已被监听，请换一个端口。"
        return 1
    fi

    uuid="$(python3 -c 'import uuid; print(uuid.uuid4())')"
    sid="$(openssl rand -hex 8)"
    generate_reality_keys "$xray" || return 1

    export INBOUND_PORT="$port" INBOUND_REMARK="$remark"
    export INBOUND_UUID="$uuid" REALITY_PRIVATE_KEY REALITY_PUBLIC_KEY
    export REALITY_SHORT_ID="$sid" REALITY_DEST="${dest}:443"
    export REALITY_SERVER_NAME="$sni"

    python3 - "$INBOUND_JSON" <<'PY'
import json, os, sys

port = int(os.environ["INBOUND_PORT"])
uuid = os.environ["INBOUND_UUID"]
remark = os.environ["INBOUND_REMARK"]
private_key = os.environ["REALITY_PRIVATE_KEY"]
short_id = os.environ["REALITY_SHORT_ID"]
dest = os.environ["REALITY_DEST"]
sni = os.environ["REALITY_SERVER_NAME"]

settings = {
    "clients": [{
        "id": uuid,
        "flow": "xtls-rprx-vision",
        "email": "xiazheteng-" + str(port),
        "enable": True,
        "limitIp": 0,
        "totalGB": 0,
        "expiryTime": 0,
        "tgId": "",
        "subId": ""
    }],
    "decryption": "none",
    "encryption": "none"
}
stream = {
    "network": "tcp",
    "security": "reality",
    "realitySettings": {
        "show": False,
        "xver": 0,
        "dest": dest,
        "serverNames": [sni],
        "privateKey": private_key,
        "shortIds": [short_id]
    }
}
sniffing = {
    "enabled": True,
    "destOverride": ["http", "tls", "quic"],
    "metadataOnly": False,
    "routeOnly": False
}
payload = {
    "up": 0, "down": 0, "total": 0,
    "remark": remark, "enable": True, "expiryTime": 0,
    "listen": "", "port": port, "protocol": "vless",
    "settings": json.dumps(settings, separators=(",", ":")),
    "streamSettings": json.dumps(stream, separators=(",", ":")),
    "sniffing": json.dumps(sniffing, separators=(",", ":"))
}
with open(sys.argv[1], "w", encoding="utf-8") as f:
    json.dump(payload, f, ensure_ascii=False, separators=(",", ":"))
PY
    chmod 600 "$INBOUND_JSON"

    info "正在向 3x-ui 添加节点……"
    api_post "/inbounds/add" "$INBOUND_JSON" || return 1
    ok "面板已确认节点添加成功。"

    echo
    echo "========== 节点参数 =========="
    echo "备注：$remark"
    echo "协议：VLESS + REALITY"
    echo "服务器：$ip"
    echo "端口：$port"
    echo "UUID：$uuid"
    echo "流控：xtls-rprx-vision"
    echo "SNI：$sni"
    echo "公钥：$REALITY_PUBLIC_KEY"
    echo "Short ID：$sid"
    echo "指纹：chrome"
    echo "=============================="

    echo
    echo "VLESS 分享链接："
    python3 - "$uuid" "$ip" "$port" "$sni" "$REALITY_PUBLIC_KEY" "$sid" "$remark" <<'PY'
import sys, urllib.parse
uuid, ip, port, sni, key, sid, remark = sys.argv[1:]
params = urllib.parse.urlencode({
    "encryption": "none",
    "flow": "xtls-rprx-vision",
    "security": "reality",
    "sni": sni,
    "fp": "chrome",
    "pbk": key,
    "sid": sid,
    "type": "tcp"
})
print(f"vless://{uuid}@{ip}:{port}?{params}#{urllib.parse.quote(remark)}")
PY

    echo
    warn "请确认云安全组和服务器防火墙允许该 TCP 端口。"
}

list_inbounds() {
    api_login || return 1
    api_get "/inbounds/list" || return 1

    python3 - "$BODY" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
items = d.get("obj") or []
if isinstance(items, dict):
    items = items.get("inbounds") or []
if not items:
    print("没有获取到入站节点。")
for x in items:
    print("-" * 55)
    print("ID：", x.get("id"))
    print("备注：", x.get("remark"))
    print("协议：", x.get("protocol"))
    print("端口：", x.get("port"))
    print("启用：", x.get("enable"))
PY
}

diagnose() {
    discover_panel || return 1
    echo
    echo "===== 服务状态 ====="
    systemctl is-active x-ui 2>/dev/null || true
    echo
    echo "===== 监听端口 ====="
    ss -lntp 2>/dev/null | grep -E ":${PANEL_PORT}\b|x-ui|xray" || true
    echo
    echo "===== 最近 15 分钟日志 ====="
    journalctl -u x-ui --since "15 minutes ago" --no-pager -n 80 2>/dev/null || true
}

restart_xui() {
    read -r -p "重启 x-ui 会短暂中断面板服务，输入 YES 确认：" answer
    [[ "$answer" == "YES" ]] || { info "已取消。"; return 0; }
    systemctl restart x-ui
    systemctl --no-pager --full status x-ui || true
}

while true; do
    echo
    echo "=============================================="
    echo " 瞎折腾吧 | 3x-ui 节点管理器"
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
            discover_panel || true
            ;;
        2)
            if api_login; then
                list_inbounds || true
            fi
            ;;
        3)
            add_reality_inbound || true
            ;;
        4)
            diagnose || true
            ;;
        5)
            restart_xui
            ;;
        0)
            rm -f "$COOKIE" "$LOGIN_JSON" "$INBOUND_JSON"
            exit 0
            ;;
        *)
            warn "无效选项。"
            ;;
    esac
done
