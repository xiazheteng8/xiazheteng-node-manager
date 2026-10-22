
#!/usr/bin/env bash
# ============================================================
# 瞎折腾吧 | VPS 节点管理器
# 支持：VLESS REALITY / VMess TCP / Shadowsocks
# 系统：Ubuntu / Debian
# 功能：自动检测、自动修复、故障隔离、统一订阅、结果汇总
# ============================================================

set -uo pipefail
umask 077

APP="xiazheteng-node-manager"
BASE="/opt/$APP"
DATA="$BASE/data"
ENV_FILE="$BASE/config.env"
COOKIE="$BASE/cookie.txt"
API_ROOT_FILE="$BASE/api-root"
TOKEN_FILE="$BASE/subscription.token"
RESULT_FILE="$BASE/deploy-results.txt"
LOG="/var/log/$APP.log"
SERVICE="xiazheteng-subscription"
SUB_PORT="${SUB_PORT:-18888}"

mkdir -p "$BASE" "$DATA" /var/log
touch "$LOG"
chmod 600 "$LOG"

log() {
    printf '[%s] %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG"
}

fail() {
    log "[失败] $*"
    return 1
}

pause() {
    printf '\n'
    read -r -p "按回车继续..." _ </dev/tty || true
}

need_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "[错误] 请使用 root 运行。"
        return 1
    fi
}

# ------------------------------------------------------------
# 通用工具
# ------------------------------------------------------------

install_dependencies() {
    export DEBIAN_FRONTEND=noninteractive

    log "[检查] 正在检查必要依赖。"

    if ! apt-get update; then
        fail "apt-get update 失败，请检查系统软件源和网络。"
        return 1
    fi

    if ! apt-get install -y \
        curl ca-certificates jq openssl python3 iproute2 \
        uuid-runtime coreutils util-linux; then
        fail "依赖安装失败。"
        return 1
    fi

    local cmd
    for cmd in curl jq openssl python3 ss awk grep sed base64; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            fail "依赖检查失败：缺少 $cmd"
            return 1
        fi
    done

    log "[成功] 依赖检查通过。"
}

get_public_ip() {
    local ip=""
    local url

    for url in \
        "https://api.ipify.org" \
        "https://ipv4.icanhazip.com" \
        "https://ifconfig.me/ip"; do

        ip="$(curl -4 -fsS --connect-timeout 4 --max-time 8 \
            "$url" 2>/dev/null | tr -d '[:space:]' || true)"

        if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
            printf '%s\n' "$ip"
            return 0
        fi
    done

    return 1
}

port_free() {
    local port="$1"

    [[ "$port" =~ ^[0-9]+$ ]] || return 1
    (( port >= 1 && port <= 65535 )) || return 1

    ! ss -H -lnt 2>/dev/null |
        awk -v p=":$port" '$4 ~ (p "$") {found=1} END {exit !found}'
}

choose_port() {
    local port

    for port in "$@"; do
        if port_free "$port"; then
            printf '%s\n' "$port"
            return 0
        fi
    done

    return 1
}

# ------------------------------------------------------------
# Xray 自动检测与密钥处理
# ------------------------------------------------------------

find_xray() {
    local candidate
    local -a candidates=(
        /usr/local/x-ui/bin/xray-linux-amd64
        /usr/local/x-ui/bin/xray
        /usr/local/x-ui/xray
        /usr/local/bin/xray
        /usr/bin/xray
    )

    for candidate in "${candidates[@]}"; do
        if [[ -x "$candidate" && ! -d "$candidate" ]]; then
            if "$candidate" version >/dev/null 2>&1 ||
               "$candidate" x25519 >/dev/null 2>&1; then
                printf '%s\n' "$candidate"
                return 0
            fi
        fi
    done

    if command -v xray >/dev/null 2>&1; then
        candidate="$(command -v xray)"
        if [[ -x "$candidate" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    fi

    # 仅在常见安装目录中寻找，不扫描整个系统。
    for candidate in /usr/local/x-ui/bin/* /usr/local/x-ui/*; do
        [[ -f "$candidate" && -x "$candidate" ]] || continue
        [[ "$(basename "$candidate")" == *xray* ]] || continue

        if "$candidate" version >/dev/null 2>&1; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    return 1
}

get_xray_reality_keys() {
    local xray="$1"
    local output
    local private=""
    local public=""

    [[ -x "$xray" ]] || {
        log "[失败] Xray 可执行文件不存在：$xray"
        return 1
    }

    log "[检查] 使用 Xray 生成 REALITY 密钥。"

    if ! output="$("$xray" x25519 2>&1)"; then
        log "[失败] Xray x25519 命令执行失败。"
        printf '%s\n' "$output" >> "$LOG"
        log "[诊断] Xray 输出已写入日志：$LOG"
        return 1
    fi

    # 兼容 PrivateKey、Private key 等不同字段大小写及空格。
    private="$(printf '%s\n' "$output" | awk '
    {
        line=$0
        sub(/^[[:space:]]*/, "", line)
        lower=tolower(line)
        if (lower ~ /^private[ _-]*key[[:space:]]*:/) {
            sub(/^[^:]*:[[:space:]]*/, "", line)
            print line
            exit
        }
    }')"

    # Xray 常见输出中的 Password 是客户端使用的公钥。
    # 同时兼容显式输出 PublicKey/Public key 的版本。
    public="$(printf '%s\n' "$output" | awk '
    {
        line=$0
        sub(/^[[:space:]]*/, "", line)
        lower=tolower(line)
        if (lower ~ /^(password|public[ _-]*key)[[:space:]]*:/) {
            sub(/^[^:]*:[[:space:]]*/, "", line)
            print line
            exit
        }
    }')"

    private="$(printf '%s' "$private" | tr -d '\r[:space:]')"
    public="$(printf '%s' "$public" | tr -d '\r[:space:]')"

    # 不猜测未知字段，也不把 Hash32 等其他值误认成公钥。
    # 如果字段无法识别，输出诊断并安全失败。
    if [[ -z "$private" || -z "$public" || "$private" == "$public" ]]; then
        log "[失败] 无法可靠识别 Xray x25519 输出格式。"
        log "[诊断] 当前 Xray 输出如下："
        while IFS= read -r line; do
            log "[Xray] $line"
        done <<< "$output"
        return 1
    fi

    if [[ ! "$private" =~ ^[A-Za-z0-9_-]{40,}$ ||
          ! "$public" =~ ^[A-Za-z0-9_-]{40,}$ ]]; then
        log "[失败] Xray 密钥格式校验失败。"
        while IFS= read -r line; do
            log "[Xray] $line"
        done <<< "$output"
        return 1
    fi

    printf '%s\n%s\n' "$private" "$public"
}

# ------------------------------------------------------------
# 3x-ui 检测与 API 登录
# ------------------------------------------------------------

detect_xui() {
    command -v x-ui >/dev/null 2>&1 ||
    [[ -x /usr/local/x-ui/x-ui ]] ||
    systemctl list-unit-files --no-legend 2>/dev/null |
        awk '{print $1}' | grep -qx 'x-ui.service'
}

install_xui() {
    if detect_xui; then
        log "[信息] 检测到已有 3x-ui，保留现有安装。"

        if ! systemctl is-active --quiet x-ui; then
            log "[修复] 3x-ui 未运行，尝试启动。"
            systemctl start x-ui || {
                fail "3x-ui 无法启动，请检查 systemctl status x-ui。"
                return 1
            }
        fi

        return 0
    fi

    log "[信息] 未检测到 3x-ui，准备运行官方安装程序。"

    local installer="$BASE/3x-ui-install.sh"

    if ! curl -4 -fsSL --retry 3 \
        https://raw.githubusercontent.com/MHSanaei/3x-ui/master/install.sh \
        -o "$installer"; then
        fail "无法下载 3x-ui 官方安装程序。"
        return 1
    fi

    chmod 700 "$installer"

    log "[警告] 官方安装程序可能需要交互，请按照其提示完成安装。"
    bash "$installer" || {
        fail "3x-ui 安装程序执行失败。"
        return 1
    }

    detect_xui || {
        fail "安装后仍未检测到 3x-ui。"
        return 1
    }

    systemctl enable --now x-ui || {
        fail "3x-ui 服务启动失败。"
        return 1
    }

    log "[成功] 3x-ui 安装检查完成。"
}

read_credentials() {
    local user pass port path

    echo
    echo "请输入现有 3x-ui 面板登录信息。"
    echo "本脚本不会自动重置现有面板密码。"
    echo "面板端口及 Web 路径必须与当前安装一致。"
    echo

    read -r -p "面板用户名：" user </dev/tty || return 1
    read -r -s -p "面板密码：" pass </dev/tty || return 1
    echo
    read -r -p "面板端口 [默认 2053]：" port </dev/tty || return 1
    read -r -p "面板 Web 路径 [默认 /]：" path </dev/tty || return 1

    port="${port:-2053}"
    path="${path:-/}"

    [[ "$port" =~ ^[0-9]+$ ]] &&
        (( port >= 1 && port <= 65535 )) || {
        fail "面板端口格式不正确。"
        return 1
    }

    [[ "$path" == /* ]] || {
        fail "面板路径必须以 / 开始。"
        return 1
    }

    [[ "$path" == */ ]] || path="$path/"

    {
        printf 'XUI_USER=%q\n' "$user"
        printf 'XUI_PASS=%q\n' "$pass"
        printf 'XUI_PORT=%q\n' "$port"
        printf 'XUI_PATH=%q\n' "$path"
    } > "$ENV_FILE"

    chmod 600 "$ENV_FILE"
    log "[成功] 面板配置已保存到 $ENV_FILE"
}

load_credentials() {
    if [[ ! -f "$ENV_FILE" ]]; then
        read_credentials || return 1
    fi

    # 文件由本脚本创建，权限为 600。
    # shellcheck disable=SC1090
    source "$ENV_FILE"

    [[ -n "${XUI_USER:-}" && -n "${XUI_PASS:-}" &&
       -n "${XUI_PORT:-}" && -n "${XUI_PATH:-}" ]] || {
        fail "面板配置缺失或不完整，请重新配置。"
        return 1
    }
}

api_login() {
    load_credentials || return 1

    local root response csrf
    local -a headers=()

    root="http://127.0.0.1:${XUI_PORT}${XUI_PATH}"

    rm -f "$COOKIE"

    csrf="$(curl -fsS --max-time 8 "$root/csrf-token" 2>/dev/null |
        jq -r '.obj // empty' 2>/dev/null || true)"

    if [[ -n "$csrf" ]]; then
        headers=(-H "X-CSRF-Token: $csrf")
    fi

    response="$(curl -sS --max-time 15 \
        -c "$COOKIE" -b "$COOKIE" \
        -H 'Content-Type: application/json' \
        "${headers[@]}" \
        -d "$(jq -cn --arg u "$XUI_USER" --arg p "$XUI_PASS" \
            '{username:$u,password:$p}')" \
        "$root/login" 2>/dev/null || true)"

    if ! jq -e '.success == true' >/dev/null 2>&1 <<< "$response"; then
        log "[失败] 3x-ui API 登录失败。"
        log "[检查] 请确认用户名、密码、端口、Web 路径及面板 API 状态。"
        log "[提示] 如面板路径或密码已变化，请重新运行菜单并更新配置。"
        return 1
    fi

    printf '%s\n' "$root" > "$API_ROOT_FILE"
    chmod 600 "$COOKIE" "$API_ROOT_FILE"

    log "[成功] 3x-ui API 登录成功。"
}

api_post() {
    local endpoint="$1"
    local body="$2"
    local root csrf response
    local -a headers=()

    [[ -s "$COOKIE" && -s "$API_ROOT_FILE" ]] || {
        fail "API 会话不存在，需要重新登录。"
        return 1
    }

    root="$(cat "$API_ROOT_FILE")"

    csrf="$(curl -fsS --max-time 8 -b "$COOKIE" \
        "$root/csrf-token" 2>/dev/null |
        jq -r '.obj // empty' 2>/dev/null || true)"

    headers=(-H 'Content-Type: application/json')
    if [[ -n "$csrf" ]]; then
        headers+=(-H "X-CSRF-Token: $csrf")
    fi

    response="$(curl -sS --max-time 20 \
        -b "$COOKIE" -c "$COOKIE" \
        "${headers[@]}" \
        -d "$body" \
        "${root}panel/api/inbounds/$endpoint" 2>/dev/null || true)"

    if ! jq -e '.success == true' >/dev/null 2>&1 <<< "$response"; then
        log "[失败] 3x-ui API 操作失败：$endpoint"
        log "[诊断] API 响应：$response"
        return 1
    fi

    printf '%s' "$response"
}

# ------------------------------------------------------------
# 节点创建
# ------------------------------------------------------------

create_reality() {
    local ip="$1" port="$2"
    local uuid short remark xray key_output private public
    local settings stream sniff body

    remark="ZT-VLESS-REALITY"
    uuid="$(cat /proc/sys/kernel/random/uuid)"
    short="$(openssl rand -hex 8)"

    xray="$(find_xray)" || {
        log "[失败] 找不到可用的 Xray 程序，REALITY 无法创建。"
        return 1
    }

    log "[信息] Xray 路径：$xray"

    key_output="$(get_xray_reality_keys "$xray")" || {
        log "[警告] REALITY 密钥生成失败，继续尝试其他协议。"
        return 1
    }

    private="$(printf '%s\n' "$key_output" | sed -n '1p')"
    public="$(printf '%s\n' "$key_output" | sed -n '2p')"

    settings="$(jq -cn --arg id "$uuid" \
        '{clients:[{id:$id,flow:"xtls-rprx-vision",email:$id}],
        decryption:"none"}')" || return 1

    stream="$(jq -cn --arg pk "$private" --arg sid "$short" \
        '{
          network:"tcp",
          security:"reality",
          realitySettings:{
            show:false,
            dest:"www.microsoft.com:443",
            xver:0,
            serverNames:["www.microsoft.com"],
            privateKey:$pk,
            shortIds:[$sid]
          }
        }')" || return 1

    sniff='{"enabled":true,"destOverride":["http","tls","quic"]}'

    body="$(jq -cn \
        --arg remark "$remark" \
        --argjson port "$port" \
        --argjson settings "$settings" \
        --argjson stream "$stream" \
        --argjson sniff "$sniff" \
        '{
          enable:true,
          remark:$remark,
          port:$port,
          protocol:"vless",
          settings:$settings,
          streamSettings:$stream,
          sniffing:$sniff,
          total:0,
          expiryTime:0
        }')" || return 1

    api_post add "$body" >/dev/null || {
        log "[失败] REALITY 入站创建失败。"
        return 1
    }

    printf 'vless://%s@%s:%s?encryption=none&security=reality&sni=www.microsoft.com&fp=chrome&pbk=%s&sid=%s&type=tcp&flow=xtls-rprx-vision#%s\n' \
        "$uuid" "$ip" "$port" "$public" "$short" "$remark" \
        >> "$DATA/nodes.txt"

    log "[成功] VLESS REALITY 入站创建成功。"
}

create_vmess() {
    local ip="$1" port="$2"
    local uuid remark settings stream sniff body vmess_json encoded

    uuid="$(cat /proc/sys/kernel/random/uuid)"
    remark="ZT-VMESS-TCP"

    settings="$(jq -cn --arg id "$uuid" \
        '{clients:[{id:$id,alterId:0,email:$id}],
        disableInsecureEncryption:false}')" || return 1

    stream='{"network":"tcp","security":"none"}'
    sniff='{"enabled":true,"destOverride":["http","tls"]}'

    body="$(jq -cn \
        --arg remark "$remark" \
        --argjson port "$port" \
        --argjson settings "$settings" \
        --argjson stream "$stream" \
        --argjson sniff "$sniff" \
        '{
          enable:true,
          remark:$remark,
          port:$port,
          protocol:"vmess",
          settings:$settings,
          streamSettings:$stream,
          sniffing:$sniff,
          total:0,
          expiryTime:0
        }')" || return 1

    api_post add "$body" >/dev/null || {
        log "[失败] VMess 入站创建失败。"
        return 1
    }

    vmess_json="$(jq -cn \
        --arg add "$ip" \
        --arg port "$port" \
        --arg id "$uuid" \
        --arg ps "$remark" \
        '{
          v:"2",ps:$ps,add:$add,port:$port,id:$id,aid:"0",
          scy:"auto",net:"tcp",type:"none",host:"",path:"",tls:""
        }')" || return 1

    encoded="$(printf '%s' "$vmess_json" | base64 -w0)" || return 1
    printf 'vmess://%s\n' "$encoded" >> "$DATA/nodes.txt"

    log "[成功] VMess TCP 入站创建成功。"
}

create_shadowsocks() {
    local ip="$1" port="$2"
    local password method remark settings stream sniff body userinfo

    password="$(openssl rand -base64 24 | tr -d '\n')" || return 1
    method="aes-128-gcm"
    remark="ZT-SHADOWSOCKS"

    settings="$(jq -cn --arg p "$password" --arg m "$method" \
        '{method:$m,password:$p,network:"tcp,udp"}')" || return 1

    stream='{"network":"tcp","security":"none"}'
    sniff='{"enabled":true,"destOverride":["http","tls"]}'

    body="$(jq -cn \
        --arg remark "$remark" \
        --argjson port "$port" \
        --argjson settings "$settings" \
        --argjson stream "$stream" \
        --argjson sniff "$sniff" \
        '{
          enable:true,
          remark:$remark,
          port:$port,
          protocol:"shadowsocks",
          settings:$settings,
          streamSettings:$stream,
          sniffing:$sniff,
          total:0,
          expiryTime:0
        }')" || return 1

    api_post add "$body" >/dev/null || {
        log "[失败] Shadowsocks 入站创建失败。"
        return 1
    }

    userinfo="$(printf '%s' "$method:$password" | base64 -w0)" || return 1

    printf 'ss://%s@%s:%s#%s\n' \
        "$userinfo" "$ip" "$port" "$remark" >> "$DATA/nodes.txt"

    log "[成功] Shadowsocks 入站创建成功。"
}

# ------------------------------------------------------------
# 统一订阅服务
# ------------------------------------------------------------

install_subscription_server() {
    local port="$1"

    SUB_PORT="$port"
    mkdir -p "$BASE" "$DATA"
    chmod 700 "$BASE" "$DATA"

    if [[ ! -s "$TOKEN_FILE" ]]; then
        log "[修复] 订阅令牌缺失，重新生成。"
        openssl rand -hex 24 > "$TOKEN_FILE" || return 1
    fi

    chmod 600 "$TOKEN_FILE"

    cat > "$BASE/subscription-server.py" <<'PYEOF'
#!/usr/bin/env python3
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import base64
import os

BASE = Path("/opt/xiazheteng-node-manager")
DATA = BASE / "data"
TOKEN_FILE = BASE / "subscription.token"
PORT = int(os.environ.get("SUB_PORT", "18888"))

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        try:
            token = TOKEN_FILE.read_text().strip()
        except Exception:
            self.send_error(503, "Subscription token unavailable")
            return

        if self.path != "/" + token:
            self.send_error(404)
            return

        node_file = DATA / "nodes.txt"

        try:
            raw = node_file.read_bytes()
        except Exception:
            self.send_error(503, "Subscription not ready")
            return

        if not raw.strip():
            self.send_error(503, "No nodes available")
            return

        payload = base64.b64encode(raw)

        self.send_response(200)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, fmt, *args):
        pass

if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
PYEOF

    chmod 700 "$BASE/subscription-server.py"

    cat > "/etc/systemd/system/${SERVICE}.service" <<EOF
[Unit]
Description=Xiazheteng Node Subscription
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=SUB_PORT=$SUB_PORT
ExecStart=/usr/bin/python3 $BASE/subscription-server.py
Restart=on-failure
RestartSec=3
User=root
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ReadOnlyPaths=$BASE/data/nodes.txt
ReadOnlyPaths=$BASE/subscription.token

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload || return 1
    systemctl enable "$SERVICE" >/dev/null 2>&1 || return 1

    if ! systemctl is-active --quiet "$SERVICE"; then
        log "[修复] 订阅服务未运行，尝试启动。"
        systemctl restart "$SERVICE" || return 1
    else
        systemctl restart "$SERVICE" || return 1
    fi

    sleep 1

    if ! systemctl is-active --quiet "$SERVICE"; then
        log "[失败] 订阅服务启动失败。"
        journalctl -u "$SERVICE" -n 40 --no-pager 2>&1 |
            while IFS= read -r line; do log "[订阅日志] $line"; done
        return 1
    fi

    if ! ss -H -lnt | awk -v p=":$SUB_PORT" \
        '$4 ~ (p "$") {found=1} END {exit !found}'; then
        log "[失败] 订阅端口 $SUB_PORT 未监听。"
        return 1
    fi

    log "[成功] 订阅服务已启动，监听端口 $SUB_PORT。"
}

verify_subscription_service() {
    local token response_file
    token="$(cat "$TOKEN_FILE" 2>/dev/null)" || return 1

    [[ -n "$token" && -s "$DATA/nodes.txt" ]] || {
        fail "订阅令牌或节点文件为空。"
        return 1
    }

    response_file="$(mktemp)"
    chmod 600 "$response_file"

    if ! curl -fsS --connect-timeout 3 --max-time 8 \
        "http://127.0.0.1:${SUB_PORT}/${token}" \
        -o "$response_file"; then

        rm -f "$response_file"
        log "[修复] 订阅本地访问失败，尝试重启服务。"

        systemctl restart "$SERVICE" || return 1
        sleep 1

        response_file="$(mktemp)"
        chmod 600 "$response_file"

        if ! curl -fsS --connect-timeout 3 --max-time 8 \
            "http://127.0.0.1:${SUB_PORT}/${token}" \
            -o "$response_file"; then
            rm -f "$response_file"
            fail "订阅服务重启后仍无法访问。"
            journalctl -u "$SERVICE" -n 40 --no-pager
            return 1
        fi
    fi

    if ! base64 -d "$response_file" 2>/dev/null |
        grep -qE '^(vless|vmess|ss)://'; then
        rm -f "$response_file"
        fail "订阅接口返回内容无效，未发现有效节点链接。"
        return 1
    fi

    rm -f "$response_file"
    log "[成功] 订阅接口本地检查通过。"
}

# ------------------------------------------------------------
# 部署流程：一个协议失败，不影响其他协议
# ------------------------------------------------------------

deploy_protocols() {
    local ip="$1" p1="$2" p2="$3" p3="$4"
    local success=0 failed=0

    : > "$DATA/nodes.txt"
    : > "$RESULT_FILE"
    chmod 600 "$DATA/nodes.txt" "$RESULT_FILE"

    log "[阶段] 开始生成 VLESS REALITY。"
    if create_reality "$ip" "$p1"; then
        echo "VLESS REALITY：成功，端口 $p1" | tee -a "$RESULT_FILE"
        success=$((success + 1))
    else
        echo "VLESS REALITY：失败，端口 $p1" | tee -a "$RESULT_FILE"
        failed=$((failed + 1))
        log "[恢复] REALITY 失败，继续生成 VMess。"
    fi

    log "[阶段] 开始生成 VMess TCP。"
    if create_vmess "$ip" "$p2"; then
        echo "VMess TCP：成功，端口 $p2" | tee -a "$RESULT_FILE"
        success=$((success + 1))
    else
        echo "VMess TCP：失败，端口 $p2" | tee -a "$RESULT_FILE"
        failed=$((failed + 1))
        log "[恢复] VMess 失败，继续生成 Shadowsocks。"
    fi

    log "[阶段] 开始生成 Shadowsocks。"
    if create_shadowsocks "$ip" "$p3"; then
        echo "Shadowsocks：成功，端口 $p3" | tee -a "$RESULT_FILE"
        success=$((success + 1))
    else
        echo "Shadowsocks：失败，端口 $p3" | tee -a "$RESULT_FILE"
        failed=$((failed + 1))
    fi

    echo
    echo "========== 协议生成汇总 =========="
    cat "$RESULT_FILE"
    echo "成功协议数：$success"
    echo "失败协议数：$failed"
    echo "=================================="

    [[ -s "$DATA/nodes.txt" ]] || {
        fail "所有协议都未生成节点，拒绝创建空订阅。"
        return 1
    }

    return 0
}

deploy_all() {
    need_root || return 1

    install_dependencies || {
        fail "依赖检查未通过，无法继续部署。"
        return 1
    }

    install_xui || return 1

    api_login || {
        fail "无法登录 3x-ui API，请检查面板配置。"
        return 1
    }

    local ip p1 p2 p3 sub_port

    ip="$(get_public_ip)" || {
        fail "无法获取公网 IPv4，请检查服务器网络。"
        return 1
    }

    log "[信息] 公网 IPv4：$ip"

    p1="$(choose_port 24443 18443 14443 10443)" || {
        fail "没有找到可用的 REALITY 候选端口。"
        return 1
    }

    p2="$(choose_port 23456 23457 23458 23459)" || {
        fail "没有找到可用的 VMess 候选端口。"
        return 1
    }

    p3="$(choose_port 23888 23889 23890 23891)" || {
        fail "没有找到可用的 Shadowsocks 候选端口。"
        return 1
    }

    # 订阅服务如果已在运行，优先复用其当前端口；
    # 否则选择空闲候选端口，避免占用其他程序的监听端口。
    if systemctl is-active --quiet "$SERVICE"; then
        local old_port
        old_port="$(systemctl show "$SERVICE" -p Environment --value 2>/dev/null |
            grep -oE 'SUB_PORT=[0-9]+' | head -n1 | cut -d= -f2 || true)"

        if [[ "$old_port" =~ ^[0-9]+$ ]] &&
           ss -H -lnt | awk -v p=":$old_port" \
             '$4 ~ (p "$") {found=1} END {exit !found}'; then
            sub_port="$old_port"
        fi
    fi

    if [[ -z "${sub_port:-}" ]]; then
        sub_port="$(choose_port 18888 18889 18890 18891)" || {
            fail "没有找到可用的订阅服务端口。"
            return 1
        }
    fi

    SUB_PORT="$sub_port"

    deploy_protocols "$ip" "$p1" "$p2" "$p3" || {
        fail "没有可用节点，订阅服务未发布。"
        return 1
    }

    install_subscription_server "$SUB_PORT" || {
        fail "订阅服务启动失败。"
        return 1
    }

    verify_subscription_service || {
        fail "订阅服务检查失败。"
        return 1
    }

    local token
    token="$(cat "$TOKEN_FILE")"

    echo
    echo "============================================================"
    echo "                 部署结果汇总"
    echo "============================================================"
    echo "公网 IPv4：$ip"
    echo
    cat "$RESULT_FILE"
    echo
    echo "统一订阅链接："
    echo "http://${ip}:${SUB_PORT}/${token}"
    echo
    echo "节点文件：$DATA/nodes.txt"
    echo "部署结果：$RESULT_FILE"
    echo "管理器日志：$LOG"
    echo
    echo "[注意] 请在云服务商防火墙放行实际创建成功的节点端口。"
    echo "[注意] 请放行 TCP $SUB_PORT，客户端才能访问订阅。"
    echo "[安全] 当前订阅为 HTTP。建议通过你已有的 HTTPS 反向代理保护订阅链接。"
    echo "[限制] 本地订阅检查不等于外网连通性或节点实际代理测试。"
    echo "============================================================"

    if (( failed > 0 )); then
        log "[警告] 部分协议失败，请查看部署汇总及日志。"
    fi

    return 0
}

# ------------------------------------------------------------
# 管理菜单
# ------------------------------------------------------------

show_menu() {
    echo
    echo "============================================================"
    echo "             瞎折腾吧 | VPS 节点管理器"
    echo "============================================================"
    echo "  1. 一键检查 / 自动修复 / 部署节点"
    echo "  2. 查看 3x-ui 状态"
    echo "  3. 查看已生成节点"
    echo "  4. 查看部署结果"
    echo "  5. 查看最近日志"
    echo "  6. 重启 3x-ui"
    echo "  7. 检查 / 重启订阅服务"
    echo "  8. 重新配置 3x-ui API 登录信息"
    echo "  0. 退出"
    echo "============================================================"
}

menu_status_xui() {
    echo
    systemctl --no-pager --full status x-ui || true
    pause
}

menu_nodes() {
    echo
    if [[ -s "$DATA/nodes.txt" ]]; then
        cat "$DATA/nodes.txt"
    else
        echo "当前没有已生成的节点。"
    fi
    pause
}

menu_results() {
    echo
    if [[ -s "$RESULT_FILE" ]]; then
        cat "$RESULT_FILE"
    else
        echo "暂无部署结果。"
    fi
    pause
}

menu_logs() {
    echo
    tail -n 100 "$LOG" 2>/dev/null || true
    pause
}

menu_subscription() {
    echo

    if ! systemctl is-active --quiet "$SERVICE"; then
        echo "[修复] 订阅服务未运行，尝试重启。"
        systemctl restart "$SERVICE" || true
    else
        systemctl restart "$SERVICE" || true
    fi

    if systemctl is-active --quiet "$SERVICE"; then
        echo "[成功] 订阅服务正在运行。"
        systemctl --no-pager --full status "$SERVICE" || true
    else
        echo "[失败] 订阅服务无法启动。"
        journalctl -u "$SERVICE" -n 40 --no-pager || true
    fi

    pause
}

main() {
    need_root || exit 1

    while true; do
        show_menu

        local choice
        if ! read -r -p "请选择 [0-8]：" choice </dev/tty; then
            echo
            echo "[错误] 无法读取终端输入。请在交互式 SSH 终端运行。"
            exit 1
        fi

        case "$choice" in
            1)
                if deploy_all; then
                    echo
                    echo "[完成] 部署流程执行结束。"
                else
                    echo
                    echo "[警告] 部署流程存在未解决的问题，请查看日志：$LOG"
                fi
                pause
                ;;
            2) menu_status_xui ;;
            3) menu_nodes ;;
            4) menu_results ;;
            5) menu_logs ;;
            6)
                if systemctl restart x-ui; then
                    echo "[成功] 已发送 3x-ui 重启请求。"
                else
                    echo "[失败] 3x-ui 重启失败。"
                fi
                pause
                ;;
            7) menu_subscription ;;
            8)
                rm -f "$ENV_FILE" "$COOKIE" "$API_ROOT_FILE"
                if read_credentials; then
                    echo "[成功] 面板配置已更新。"
                else
                    echo "[失败] 面板配置更新失败。"
                fi
                pause
                ;;
            0)
                echo "已退出。"
                exit 0
                ;;
            *)
                echo "[错误] 无效选项，请输入 0-8。"
                ;;
        esac
    done
}

main "$@"
