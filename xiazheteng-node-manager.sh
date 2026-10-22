#!/usr/bin/env bash
# ============================================================
# 瞎折腾吧 | 3x-ui / Xray 节点管理器
# 单文件版本：复用已有 3x-ui，不重建数据库，不删除已有节点
# 修复重点：JSON 登录、自定义 Base Path、403 诊断、避免重复登录
# ============================================================

set -Eeuo pipefail
umask 077

APP_NAME="瞎折腾吧 | VPS 节点管理器"
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")"
DB="/etc/x-ui/x-ui.db"
WORK_DIR="/tmp/xiazheteng-node-manager"
COOKIE_JAR="$WORK_DIR/cookies.txt"
RESPONSE_FILE="$WORK_DIR/response.txt"
LOGIN_JSON="$WORK_DIR/login.json"
INBOUND_JSON="$WORK_DIR/inbound.json"

mkdir -p "$WORK_DIR"
chmod 700 "$WORK_DIR"

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
    read -r -p "按回车键继续..." _
}

need_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        err "请使用 root 运行：sudo bash $SCRIPT_PATH"
        exit 1
    fi
}

check_dependencies() {
    local missing=()
    for cmd in curl python3 openssl; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done

    if ((${#missing[@]})); then
        err "缺少依赖：${missing[*]}"
        echo "Debian/Ubuntu 可执行："
        echo "apt-get update && apt-get install -y curl python3 openssl"
        return 1
    fi

    if ! command -v jq >/dev/null 2>&1; then
        warn "未检测到 jq，部分 JSON 操作将使用 Python 处理。"
    fi
}

# ------------------------------------------------------------
# 读取 3x-ui 数据库设置
# 不打印密码；不修改数据库
# ------------------------------------------------------------
db_setting() {
    local key="$1"

    [[ -f "$DB" ]] || return 1

    python3 - "$DB" "$key" <<'PY'
import sqlite3, sys

db, wanted = sys.argv[1], sys.argv[2]
try:
    con = sqlite3.connect(f"file:{db}?mode=ro", uri=True, timeout=3)
    tables = con.execute(
        "SELECT name FROM sqlite_master WHERE type='table'"
    ).fetchall()

    aliases = {
        "username": ["username", "webUser", "webUsername"],
        "password": ["password", "webPass", "webPassword"],
        "webPort": ["webPort", "port"],
        "webBasePath": ["webBasePath", "basePath", "webPath"],
        "webListen": ["webListen", "listen"],
    }
    candidates = aliases.get(wanted, [wanted])

    for (table,) in tables:
        cols = [r[1] for r in con.execute(f'PRAGMA table_info("{table}")')]
        if "key" in cols and "value" in cols:
            for key in candidates:
                row = con.execute(
                    f'SELECT value FROM "{table}" WHERE key=? LIMIT 1',
                    (key,)
                ).fetchone()
                if row and row[0] is not None and str(row[0]) != "":
                    print(str(row[0]))
                    con.close()
                    sys.exit(0)

        # 某些版本使用单行 settings 表
        for key in candidates:
            if key in cols:
                row = con.execute(
                    f'SELECT "{key}" FROM "{table}" LIMIT 1'
                ).fetchone()
                if row and row[0] is not None and str(row[0]) != "":
                    print(str(row[0]))
                    con.close()
                    sys.exit(0)

    con.close()
except Exception:
    pass
sys.exit(1)
PY
}

# 尝试从官方 CLI 读取设置；不自动更改设置
cli_settings() {
    local cli=""
    for p in /usr/local/x-ui/x-ui /usr/bin/x-ui /usr/local/bin/x-ui; do
        if [[ -x "$p" ]]; then
            cli="$p"
            break
        fi
    done

    if [[ -n "$cli" ]]; then
        "$cli" setting -show 2>/dev/null || true
    elif command -v x-ui >/dev/null 2>&1; then
        x-ui setting -show 2>/dev/null || true
    fi
}

normalise_base_path() {
    local p="${1:-/}"

    [[ -n "$p" ]] || p="/"

    if [[ "$p" != /* ]]; then
        p="/$p"
    fi

    if [[ "$p" != */ ]]; then
        p="$p/"
    fi

    printf '%s' "$p"
}

discover_panel() {
    PANEL_PORT="$(db_setting webPort 2>/dev/null || true)"
    PANEL_BASE="$(db_setting webBasePath 2>/dev/null || true)"
    PANEL_USER="$(db_setting username 2>/dev/null || true)"
    PANEL_PASS="$(db_setting password 2>/dev/null || true)"

    # CLI 作为补充信息，不能保证所有版本都以相同格式输出
    if [[ -z "$PANEL_PORT" || -z "$PANEL_BASE" ]]; then
        local settings=""
        settings="$(cli_settings)"
        if [[ -z "$PANEL_PORT" ]]; then
            PANEL_PORT="$(printf '%s\n' "$settings" |
                sed -nE 's/.*webPort[^0-9]*([0-9]{2,5}).*/\1/p' |
                head -n1)"
        fi
        if [[ -z "$PANEL_BASE" ]]; then
            PANEL_BASE="$(printf '%s\n' "$settings" |
                sed -nE 's/.*webBasePath[^[:alnum:]\/]*([^[:space:]]+).*/\1/p' |
                head -n1)"
        fi
    fi

    [[ "$PANEL_PORT" =~ ^[0-9]{1,5}$ ]] || PANEL_PORT="2053"
    PANEL_BASE="$(normalise_base_path "${PANEL_BASE:-/}")"

    # 使用回环地址访问本机面板，避免依赖公网域名和 Cloudflare
    PANEL_ORIGIN="http://127.0.0.1:${PANEL_PORT}"
    PANEL_PREFIX="${PANEL_ORIGIN}${PANEL_BASE}"
    LOGIN_URL="${PANEL_PREFIX%/}/login"
    API_PREFIX="${PANEL_PREFIX%/}/panel/api"

    info "面板本地地址：$PANEL_ORIGIN"
    info "面板访问路径：$PANEL_BASE"
}

# ------------------------------------------------------------
# API 请求封装
# ------------------------------------------------------------
api_request() {
    local method="$1"
    local endpoint="$2"
    local data="${3:-}"
    local url="${API_PREFIX}${endpoint}"
    local status

    : > "$RESPONSE_FILE"

    if [[ "$method" == "GET" ]]; then
        status="$(curl -sS --connect-timeout 3 --max-time 15 \
            -b "$COOKIE_JAR" -c "$COOKIE_JAR" \
            -o "$RESPONSE_FILE" -w '%{http_code}' \
            "$url" 2>"$WORK_DIR/curl-error.txt" || true)"
    else
        status="$(curl -sS --connect-timeout 3 --max-time 20 \
            -b "$COOKIE_JAR" -c "$COOKIE_JAR" \
            -H 'Content-Type: application/json' \
            --data-binary "@$data" \
            -o "$RESPONSE_FILE" -w '%{http_code}' \
            "$url" 2>"$WORK_DIR/curl-error.txt" || true)"
    fi

    printf '%s' "${status:-000}"
}

api_login() {
    discover_panel

    # 如果数据库中没有可靠的凭据，要求用户输入，不猜测默认密码。
    if [[ -z "${PANEL_USER:-}" ]]; then
        read -r -p "请输入 3x-ui 用户名：" PANEL_USER
    else
        info "已从本地设置数据库读取用户名。"
    fi

    if [[ -z "${PANEL_PASS:-}" ]]; then
        read -r -s -p "请输入 3x-ui 密码：" PANEL_PASS
        echo
    else
        info "已从本地设置数据库读取密码。"
    fi

    if [[ -z "$PANEL_USER" || -z "$PANEL_PASS" ]]; then
        err "用户名或密码为空。"
        return 1
    fi

    # 先检测面板实际响应，防止把 404 当作登录失败
    local probe_status
    probe_status="$(curl -sS --connect-timeout 3 --max-time 8 \
        -o "$RESPONSE_FILE" -w '%{http_code}' \
        "$LOGIN_URL" 2>"$WORK_DIR/curl-error.txt" || true)"

    if [[ "${probe_status:-000}" == "000" ]]; then
        err "无法连接面板：$LOGIN_URL"
        cat "$WORK_DIR/curl-error.txt" 2>/dev/null || true
        err "请确认端口、监听地址和服务状态。"
        return 1
    fi

    if [[ "$probe_status" == "404" ]]; then
        err "登录路径返回 404，当前 Base Path 可能不正确。"
        echo "已检测路径：$LOGIN_URL"
        echo "不会尝试猜测密码，也不会修改数据库。"
        return 1
    fi

    # 使用 JSON 请求体；明确包含 twoFactorCode 空字段
    python3 - "$LOGIN_JSON" "$PANEL_USER" "$PANEL_PASS" <<'PY'
import json, sys
path, username, password = sys.argv[1:]
with open(path, "w", encoding="utf-8") as f:
    json.dump({
        "username": username,
        "password": password,
        "twoFactorCode": ""
    }, f)
PY
    chmod 600 "$LOGIN_JSON"

    # 只尝试一次登录，避免反复触发 403 / 登录限流
    : > "$COOKIE_JAR"
    local status
    status="$(curl -sS --connect-timeout 3 --max-time 15 \
        -X POST \
        -H 'Content-Type: application/json' \
        -H 'Accept: application/json' \
        -c "$COOKIE_JAR" -b "$COOKIE_JAR" \
        --data-binary "@$LOGIN_JSON" \
        -o "$RESPONSE_FILE" -w '%{http_code}' \
        "$LOGIN_URL" 2>"$WORK_DIR/curl-error.txt" || true)"

    rm -f "$LOGIN_JSON"

    if [[ "${status:-000}" == "200" ]] &&
       python3 - "$RESPONSE_FILE" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1], encoding="utf-8"))
    sys.exit(0 if d.get("success") is True or d.get("success") == 1
             or d.get("msg") == "登录成功" or d.get("code") == 0 else 1)
except Exception:
    sys.exit(1)
PY
    then
        ok "面板 API 登录成功。"
        return 0
    fi

    err "面板 API 登录失败，HTTP 状态码：${status:-000}"
    echo "服务器响应："
    python3 - "$RESPONSE_FILE" <<'PY'
import sys
try:
    s = open(sys.argv[1], encoding="utf-8", errors="replace").read()
    print(s[:1200] if s else "(空响应)")
except Exception:
    print("(无法读取响应)")
PY

    case "${status:-000}" in
        403)
            warn "HTTP 403：可能是凭据错误、登录限流、二步验证或版本差异。"
            warn "脚本不会连续重试、重置密码或关闭安全机制。"
            echo "建议先检查："
            echo "  1. 等待可能的登录限制解除；"
            echo "  2. 确认面板用户名、密码及二步验证设置；"
            echo "  3. 查看日志：journalctl -u x-ui --since '15 minutes ago' --no-pager"
            ;;
        404)
            warn "登录接口路径不存在，可能是自定义 Base Path 或版本路由不同。"
            ;;
        301|302|307|308)
            warn "面板返回重定向，可能需要 HTTPS 或其他访问路径。"
            ;;
        *)
            warn "请检查面板设置、日志和当前版本 API 路由。"
            ;;
    esac

    if [[ -s "$WORK_DIR/curl-error.txt" ]]; then
        cat "$WORK_DIR/curl-error.txt"
    fi

    return 1
}

# ------------------------------------------------------------
# 节点工具
# ------------------------------------------------------------
find_xray() {
    local x
    for x in \
        /usr/local/x-ui/bin/xray \
        /usr/local/bin/xray \
        /usr/bin/xray; do
        if [[ -x "$x" ]]; then
            printf '%s' "$x"
            return 0
        fi
    done

    if command -v xray >/dev/null 2>&1; then
        command -v xray
        return 0
    fi
    return 1
}

gen_uuid() {
    python3 -c 'import uuid; print(uuid.uuid4())'
}

random_port() {
    python3 - <<'PY'
import socket, random
for _ in range(100):
    p = random.randint(20000, 60000)
    s = socket.socket()
    try:
        s.bind(("0.0.0.0", p))
        print(p)
        s.close()
        break
    except OSError:
        s.close()
PY
}

get_public_ipv4() {
    local ip=""
    for url in \
        https://api.ipify.org \
        https://ipv4.icanhazip.com \
        https://checkip.amazonaws.com; do
        ip="$(curl -4 -fsS --connect-timeout 3 --max-time 5 "$url" 2>/dev/null |
            tr -d '[:space:]' || true)"
        if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
            printf '%s' "$ip"
            return 0
        fi
    done
    return 1
}

generate_reality_keys() {
    local xray_bin="$1"
    local output=""

    output="$("$xray_bin" x25519 2>&1)" || {
        err "执行 xray x25519 失败。"
        printf '%s\n' "$output"
        return 1
    }

    # 新版 Xray：PrivateKey 为服务端私钥，Password 通常对应客户端公钥。
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

    # 兼容部分旧版本输出格式
    if [[ -z "$REALITY_PRIVATE_KEY" ]]; then
        REALITY_PRIVATE_KEY="$(
            printf '%s\n' "$output" |
            sed -nE 's/^[[:space:]]*Private[[:space:]]*key:[[:space:]]*([^[:space:]]+).*$/\1/p' |
            head -n1
        )"
    fi
    if [[ -z "$REALITY_PUBLIC_KEY" ]]; then
        REALITY_PUBLIC_KEY="$(
            printf '%s\n' "$output" |
            sed -nE 's/^[[:space:]]*(Public[[:space:]]*key|PublicKey):[[:space:]]*([^[:space:]]+).*$/\2/p' |
            head -n1
        )"
    fi

    if [[ -z "$REALITY_PRIVATE_KEY" || -z "$REALITY_PUBLIC_KEY" ]]; then
        err "无法从当前 Xray 输出中识别 REALITY 密钥。"
        echo "Xray 输出如下，请检查输出格式："
        printf '%s\n' "$output"
        return 1
    fi
}

add_reality_inbound() {
    local xray_bin
    xray_bin="$(find_xray)" || {
        err "未找到 Xray 可执行文件。"
        return 1
    }

    api_login || return 1

    local public_ip port uuid short_id dest server_name remark flow
    public_ip="$(get_public_ipv4 || true)"
    if [[ -z "$public_ip" ]]; then
        read -r -p "无法自动获取公网 IPv4，请输入服务器公网 IP：" public_ip
    fi

    read -r -p "节点备注 [Xiazheteng-REALITY]：" remark
    remark="${remark:-Xiazheteng-REALITY}"

    read -r -p "REALITY 目标域名 [www.microsoft.com]：" dest
    dest="${dest:-www.microsoft.com}"

    read -r -p "监听端口（留空自动选择）：" port
    if [[ -z "$port" ]]; then
        port="$(random_port)"
    fi

    if [[ ! "$port" =~ ^[0-9]+$ ]] || ((port < 1 || port > 65535)); then
        err "端口无效。"
        return 1
    fi

    if ss -lnt 2>/dev/null | awk '{print $4}' |
       grep -Eq "(:|\])${port}$"; then
        err "端口 $port 已被监听，请选择其他端口。"
        return 1
    fi

    server_name="${dest%%:*}"
    [[ -n "$server_name" ]] || server_name="www.microsoft.com"
    uuid="$(gen_uuid)"
    short_id="$(openssl rand -hex 8)"

    generate_reality_keys "$xray_bin" || return 1

    # 使用 Python 生成严格 JSON，避免备注、域名等字段破坏 JSON 格式
    export INBOUND_PORT="$port"
    export INBOUND_REMARK="$remark"
    export INBOUND_UUID="$uuid"
    export REALITY_PRIVATE_KEY REALITY_PUBLIC_KEY
    export REALITY_SHORT_ID="$short_id"
    export REALITY_DEST="${dest}:443"
    export REALITY_SERVER_NAME="$server_name"

    python3 - "$INBOUND_JSON" <<'PY'
import json, os, sys

port = int(os.environ["INBOUND_PORT"])
remark = os.environ["INBOUND_REMARK"]
uuid = os.environ["INBOUND_UUID"]
private_key = os.environ["REALITY_PRIVATE_KEY"]
short_id = os.environ["REALITY_SHORT_ID"]
dest = os.environ["REALITY_DEST"]
server_name = os.environ["REALITY_SERVER_NAME"]

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
        "serverNames": [server_name],
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
    "up": 0,
    "down": 0,
    "total": 0,
    "remark": remark,
    "enable": True,
    "expiryTime": 0,
    "listen": "",
    "port": port,
    "protocol": "vless",
    "settings": json.dumps(settings, separators=(",", ":")),
    "streamSettings": json.dumps(stream, separators=(",", ":")),
    "sniffing": json.dumps(sniffing, separators=(",", ":"))
}

with open(sys.argv[1], "w", encoding="utf-8") as f:
    json.dump(payload, f, ensure_ascii=False, separators=(",", ":"))
PY

    chmod 600 "$INBOUND_JSON"

    info "正在创建 VLESS + REALITY 节点……"
    local status
    status="$(api_request POST "/inbounds/add" "$INBOUND_JSON")"

    if [[ "$status" != "200" ]]; then
        err "创建节点请求失败，HTTP 状态码：$status"
        cat "$RESPONSE_FILE" 2>/dev/null || true
        return 1
    fi

    if ! python3 - "$RESPONSE_FILE" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1], encoding="utf-8"))
    sys.exit(0 if d.get("success") is True or d.get("success") == 1
             or d.get("code") == 0 else 1)
except Exception:
    sys.exit(1)
PY
    then
        err "面板没有确认创建成功，返回内容："
        cat "$RESPONSE_FILE"
        return 1
    fi

    ok "节点创建请求已被面板接受。"
    echo
    echo "================ 节点参数 ================"
    echo "备注：       $remark"
    echo "协议：       VLESS + REALITY"
    echo "服务器：     $public_ip"
    echo "端口：       $port"
    echo "UUID：       $uuid"
    echo "流控：       xtls-rprx-vision"
    echo "传输：       TCP"
    echo "SNI：        $server_name"
    echo "公钥：       $REALITY_PUBLIC_KEY"
    echo "Short ID：   $short_id"
    echo "指纹：       chrome"
    echo "=========================================="

    local link
    link="vless://${uuid}@${public_ip}:${port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${server_name}&fp=chrome&pbk=${REALITY_PUBLIC_KEY}&sid=${short_id}&type=tcp&headerType=none#${remark// /%20}"

    echo
    echo "VLESS 分享链接："
    printf '%s\n' "$link"
    echo
    echo "注意：请确认云服务商安全组和服务器防火墙已允许该端口。"
    echo "脚本不会自动开放云厂商安全组，也不会修改现有防火墙策略。"

    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
        echo
        warn "检测到 UFW 正在运行。如确认需要开放端口，可执行："
        echo "ufw allow ${port}/tcp"
    fi
}

list_inbounds() {
    api_login || return 1

    local status
    status="$(api_request GET "/inbounds/list")"

    if [[ "$status" != "200" ]]; then
        err "获取节点列表失败，HTTP 状态码：$status"
        cat "$RESPONSE_FILE" 2>/dev/null || true
        return 1
    fi

    python3 - "$RESPONSE_FILE" <<'PY'
import json, sys
try:
    data = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception as e:
    print("无法解析面板响应：", e)
    sys.exit(1)

if not data.get("success", False):
    print("面板返回失败：", data.get("msg", data))
    sys.exit(1)

obj = data.get("obj") or []
if isinstance(obj, dict):
    obj = obj.get("inbounds") or []

if not obj:
    print("当前没有返回节点数据。")
else:
    print("\n当前入站列表：")
    print("-" * 78)
    for item in obj:
        print("ID:       ", item.get("id", ""))
        print("备注:     ", item.get("remark", ""))
        print("协议:     ", item.get("protocol", ""))
        print("端口:     ", item.get("port", ""))
        print("启用:     ", item.get("enable", ""))
        print("-" * 78)
PY
}

diagnose() {
    echo
    echo "========== 环境诊断 =========="
    echo "系统：$(uname -a)"
    echo "数据库：$([[ -f "$DB" ]] && echo 存在 || echo 不存在)"
    echo "x-ui 服务："
    systemctl is-active x-ui 2>/dev/null || true

    echo
    echo "监听端口："
    ss -lntp 2>/dev/null | grep -E 'x-ui|xray|:22682|:2096' || true

    echo
    echo "面板设置（请勿把含有密码的输出公开）："
    discover_panel
    echo "本地面板：$PANEL_ORIGIN"
    echo "Base Path：$PANEL_BASE"

    echo
    echo "最近 15 分钟 x-ui 日志："
    journalctl -u x-ui --since "15 minutes ago" --no-pager -n 80 2>/dev/null || true

    echo
    echo "若 API 登录返回 403，脚本不会自动重置用户名/密码。"
    echo "先检查登录限流、二步验证、Base Path 和日志。"
}

restart_xui() {
    echo "此操作会短暂中断面板和由它管理的服务。"
    read -r -p "确认重启 x-ui？输入 YES 继续：" confirm
    [[ "$confirm" == "YES" ]] || {
        info "已取消。"
        return 0
    }

    systemctl restart x-ui
    sleep 2
    systemctl --no-pager --full status x-ui || true
}

show_menu() {
    clear 2>/dev/null || true
    echo "=================================================="
    echo " $APP_NAME"
    echo "=================================================="
    echo " 1. 检查环境和面板设置"
    echo " 2. 测试 API 登录并列出节点"
    echo " 3. 新建 VLESS + REALITY 节点"
    echo " 4. 查看 x-ui 服务状态"
    echo " 5. 查看 API / 403 诊断信息"
    echo " 6. 重启 x-ui 服务"
    echo " 0. 退出"
    echo "=================================================="
}

main() {
    need_root
    check_dependencies || exit 1

    if [[ ! -f "$DB" ]]; then
        warn "没有找到 $DB。"
        warn "此脚本面向已安装的 3x-ui，不会自动安装或覆盖数据库。"
    fi

    while true; do
        show_menu
        read -r -p "请选择 [0-6]：" choice

        case "$choice" in
            1)
                discover_panel
                echo "x-ui 服务："
                systemctl --no-pager --full status x-ui 2>/dev/null || true
                pause
                ;;
            2)
                if api_login; then
                    list_inbounds || true
                fi
                pause
                ;;
            3)
                add_reality_inbound || true
                pause
                ;;
            4)
                systemctl --no-pager --full status x-ui 2>/dev/null || true
                pause
                ;;
            5)
                diagnose
                pause
                ;;
            6)
                restart_xui
                pause
                ;;
            0)
                rm -f "$COOKIE_JAR" "$LOGIN_JSON" "$INBOUND_JSON"
                echo "已退出。"
                exit 0
                ;;
            *)
                warn "无效选项。"
                sleep 1
                ;;
        esac
    done
}

main "$@"
