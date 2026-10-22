
#!/usr/bin/env bash
# ============================================================
# 瞎折腾吧 | VPS 节点管理器（兼容修复版）
# Ubuntu / Debian
# VLESS REALITY + VLESS TLS + VMess TCP + Shadowsocks
# 自动检测、故障隔离、订阅检查、TLS 证书管理
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
SUB_PORT=18888

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
    read -r -p "按回车继续..." _ </dev/tty || true
}

need_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "[错误] 请使用 root 运行。"
        return 1
    fi
}

# ------------------------------------------------------------
# 基础工具
# ------------------------------------------------------------

install_dependencies() {
    export DEBIAN_FRONTEND=noninteractive

    log "[检查] 安装必要依赖。"

    apt-get update || {
        fail "apt-get update 失败，请检查系统软件源和网络。"
        return 1
    }

    apt-get install -y \
        curl ca-certificates jq openssl python3 iproute2 \
        uuid-runtime coreutils util-linux dnsutils certbot \
        python3-certbot-nginx || {
        fail "依赖安装失败。"
        return 1
    }

    local cmd
    for cmd in curl jq openssl python3 ss awk grep sed base64 certbot; do
        command -v "$cmd" >/dev/null 2>&1 || {
            fail "缺少必要命令：$cmd"
            return 1
        }
    done

    log "[成功] 依赖检查通过。"
}

get_public_ip() {
    local ip url

    for url in \
        https://api.ipify.org \
        https://ipv4.icanhazip.com \
        https://ifconfig.me/ip; do

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

open_ufw_port_if_active() {
    local port="$1"

    if command -v ufw >/dev/null 2>&1 &&
       ufw status 2>/dev/null | grep -q 'Status: active'; then

        if ufw allow "${port}/tcp"; then
            log "[修复] 已在 UFW 中允许 TCP $port。"
        else
            log "[警告] UFW 放行失败：TCP $port。"
        fi
    fi

    # 不自动清空 iptables/nftables 规则。
    # 云厂商安全组需要用户在服务商控制台放行。
}

# ------------------------------------------------------------
# 3x-ui 检测和 API
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
            log "[修复] 尝试启动现有 3x-ui。"
            systemctl start x-ui || {
                fail "3x-ui 启动失败，请检查 systemctl status x-ui。"
                return 1
            }
        fi

        return 0
    fi

    log "[信息] 未检测到 3x-ui，下载官方安装程序。"

    local installer="$BASE/3x-ui-install.sh"

    curl -4 -fsSL --retry 3 \
        https://raw.githubusercontent.com/MHSanaei/3x-ui/master/install.sh \
        -o "$installer" || {
        fail "下载 3x-ui 官方安装程序失败。"
        return 1
    }

    chmod 700 "$installer"

    echo "[注意] 接下来可能进入官方安装程序的交互界面。"
    bash "$installer" || {
        fail "3x-ui 安装程序执行失败。"
        return 1
    }

    detect_xui || {
        fail "安装结束后仍未检测到 3x-ui。"
        return 1
    }

    systemctl enable --now x-ui || return 1
}

detect_xui_port() {
    # 从 x-ui 进程实际监听的 TCP 套接字自动识别面板端口。
    ss -H -lntp 2>/dev/null | awk '
        /users:\(\("x-ui"/ {
            addr=$4
            sub(/^.*:/, "", addr)
            if (addr ~ /^[0-9]+$/ && addr > 0 && addr <= 65535) {
                print addr
                exit
            }
        }
    '
}

read_credentials() {
    local user pass port path detected_port
    detected_port="$(detect_xui_port || true)"

    echo
    echo "请输入当前 3x-ui 面板登录信息。"
    echo "脚本不会擅自重置已有面板密码。"

    read -r -p "面板用户名：" user </dev/tty || return 1
    read -r -s -p "面板密码：" pass </dev/tty || return 1
    echo
    read -r -p "面板端口 [默认 ${detected_port:-2053}]：" port </dev/tty || return 1
    read -r -p "面板 Web 路径 [默认 /]：" path </dev/tty || return 1

    port="${port:-${detected_port:-2053}}"
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
}

load_credentials() {
    [[ -f "$ENV_FILE" ]] || read_credentials || return 1

    # shellcheck disable=SC1090
    source "$ENV_FILE"

    [[ -n "${XUI_USER:-}" &&
       -n "${XUI_PASS:-}" &&
       -n "${XUI_PORT:-}" &&
       -n "${XUI_PATH:-}" ]] || {
        fail "面板配置不完整，请重新配置。"
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

    [[ -z "$csrf" ]] || headers=(-H "X-CSRF-Token: $csrf")

    response="$(curl -sS --max-time 15 \
        -c "$COOKIE" -b "$COOKIE" \
        -H 'Content-Type: application/json' \
        "${headers[@]}" \
        -d "$(jq -cn --arg u "$XUI_USER" --arg p "$XUI_PASS" \
            '{username:$u,password:$p}')" \
        "$root/login" 2>/dev/null || true)"

    if ! jq -e '.success == true' >/dev/null 2>&1 <<< "$response"; then
        log "[失败] 3x-ui API 登录失败。"
        log "[检查] 请确认面板用户名、密码、端口和 Web 路径。"
        return 1
    fi

    printf '%s\n' "$root" > "$API_ROOT_FILE"
    chmod 600 "$COOKIE" "$API_ROOT_FILE"

    log "[成功] 3x-ui API 登录成功。"
}

api_post() {
    local endpoint="$1" body="$2"
    local root csrf response
    local -a headers=()

    [[ -s "$COOKIE" && -s "$API_ROOT_FILE" ]] || {
        fail "API 会话不存在。"
        return 1
    }

    root="$(cat "$API_ROOT_FILE")"

    csrf="$(curl -fsS --max-time 8 -b "$COOKIE" \
        "$root/csrf-token" 2>/dev/null |
        jq -r '.obj // empty' 2>/dev/null || true)"

    headers=(-H 'Content-Type: application/json')
    [[ -z "$csrf" ]] || headers+=(-H "X-CSRF-Token: $csrf")

    response="$(curl -sS --max-time 20 \
        -b "$COOKIE" -c "$COOKIE" \
        "${headers[@]}" -d "$body" \
        "${root}panel/api/inbounds/$endpoint" 2>/dev/null || true)"

    if ! jq -e '.success == true' >/dev/null 2>&1 <<< "$response"; then
        log "[失败] 3x-ui API 操作失败：$endpoint"
        log "[诊断] API 响应：$response"
        return 1
    fi

    printf '%s' "$response"
}

# ------------------------------------------------------------
# Xray 密钥检测
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
        [[ -x "$candidate" && ! -d "$candidate" ]] || continue

        if "$candidate" version >/dev/null 2>&1; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    if command -v xray >/dev/null 2>&1; then
        command -v xray
        return 0
    fi

    return 1
}

get_xray_reality_keys() {
    local xray="$1" output private public

    output="$("$xray" x25519 2>&1)" || {
        log "[失败] Xray x25519 命令执行失败。"
        while IFS= read -r line; do log "[Xray] $line"; done <<< "$output"
        return 1
    }

    private="$(printf '%s\n' "$output" | awk '
    {
        line=$0
        sub(/^[[:space:]]*/, "", line)
        if (tolower(line) ~ /^private[ _-]*key[[:space:]]*:/) {
            sub(/^[^:]*:[[:space:]]*/, "", line)
            print line
            exit
        }
    }')"

    public="$(printf '%s\n' "$output" | awk '
    {
        line=$0
        sub(/^[[:space:]]*/, "", line)
        if (tolower(line) ~ /^(password|public[ _-]*key)[[:space:]]*:/) {
            sub(/^[^:]*:[[:space:]]*/, "", line)
            print line
            exit
        }
    }')"

    private="$(printf '%s' "$private" | tr -d '\r[:space:]')"
    public="$(printf '%s' "$public" | tr -d '\r[:space:]')"

    if [[ ! "$private" =~ ^[A-Za-z0-9_-]{40,}$ ||
          ! "$public" =~ ^[A-Za-z0-9_-]{40,}$ ||
          "$private" == "$public" ]]; then
        log "[失败] 无法可靠识别 Xray x25519 输出格式。"
        while IFS= read -r line; do log "[Xray] $line"; done <<< "$output"
        return 1
    fi

    printf '%s\n%s\n' "$private" "$public"
}

# ------------------------------------------------------------
# 域名 / TLS 证书
# ------------------------------------------------------------

ask_domain_mode() {
    local answer

    echo
    echo "是否使用域名部署 VLESS TLS 节点？"
    echo "  1. 是，输入域名并自动检查证书"
    echo "  2. 否，跳过 TLS 节点"
    echo "  也可以直接输入域名，例如 xiazheteng.fun"
    read -r -p "请选择 [默认 2]：" answer </dev/tty || return 1

    case "${answer:-2}" in
        1)
            read -r -p "请输入已解析到本 VPS 的域名：" TLS_DOMAIN </dev/tty || return 1
            ;;
        2)
            USE_TLS=0
            TLS_DOMAIN=""
            return 0
            ;;
        *)
            # 兼容用户在选项提示处直接输入域名的操作方式。
            TLS_DOMAIN="$answer"
            ;;
    esac

    TLS_DOMAIN="${TLS_DOMAIN,,}"
    TLS_DOMAIN="${TLS_DOMAIN%.}"

    if [[ ! "$TLS_DOMAIN" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ||
          "$TLS_DOMAIN" == *..* ]]; then
        fail "域名格式不正确。"
        return 1
    fi

    USE_TLS=1
}

obtain_tls_certificate() {
    local domain="$1"
    local public_ip cert_dir fullchain privkey
    local dns_result

    cert_dir="/etc/letsencrypt/live/$domain"
    fullchain="$cert_dir/fullchain.pem"
    privkey="$cert_dir/privkey.pem"

    public_ip="$(get_public_ip)" || {
        fail "无法获取公网 IPv4，无法检查域名解析。"
        return 1
    }

    dns_result="$(getent ahostsv4 "$domain" 2>/dev/null |
        awk '{print $1}' | sort -u || true)"

    if [[ -z "$dns_result" ]]; then
        fail "域名 $domain 没有可查询到的 IPv4 解析。"
        return 1
    fi

    echo "[信息] 域名 IPv4 解析结果："
    printf '%s\n' "$dns_result"
    echo "[信息] 当前 VPS 公网 IPv4：$public_ip"

    if ! grep -Fxq "$public_ip" <<< "$dns_result"; then
        log "[警告] DNS 解析结果未直接包含本机 IP。"
        log "[提示] 如果使用 CDN 代理，请确认源站地址及 HTTP 验证可用。"
    fi

    if [[ -s "$fullchain" && -s "$privkey" ]] &&
       openssl x509 -in "$fullchain" -noout -checkend 86400 >/dev/null 2>&1; then
        if openssl x509 -in "$fullchain" -noout -ext subjectAltName 2>/dev/null |
            grep -Fq "$domain"; then
            log "[成功] 检测到可用证书：$fullchain"
            return 0
        fi
    fi

    log "[信息] 未找到有效证书，尝试自动申请。"

    # 不覆盖现有 Nginx 配置，也不终止正在运行的服务。
    # Nginx 存在时使用 certbot nginx authenticator。
    # 没有 Nginx 时才使用 standalone。
    if systemctl is-active --quiet nginx; then
        log "[信息] 检测到 Nginx，尝试使用 Certbot Nginx 插件验证域名。"

        certbot certonly --nginx \
            -d "$domain" \
            --non-interactive \
            --agree-tos \
            --register-unsafely-without-email \
            --preferred-challenges http || {
            fail "通过现有 Nginx 申请证书失败。未删除或覆盖现有站点。"
            log "[建议] 检查域名解析、80 端口、Nginx server_name 和 CDN 配置。"
            return 1
        }
    else
        if ! port_free 80; then
            fail "80 端口被其他程序占用，且没有可用的 Nginx 验证方式。"
            log "[建议] 请配置 DNS-01 验证，或先确认现有 Web 服务的验证方式。"
            return 1
        fi

        certbot certonly --standalone \
            -d "$domain" \
            --non-interactive \
            --agree-tos \
            --register-unsafely-without-email \
            --preferred-challenges http || {
            fail "Certbot 申请证书失败。"
            return 1
        }
    fi

    [[ -s "$fullchain" && -s "$privkey" ]] || {
        fail "Certbot 执行后仍未找到完整证书文件。"
        return 1
    }

    openssl x509 -in "$fullchain" -noout -checkend 86400 >/dev/null 2>&1 || {
        fail "证书有效期检查失败。"
        return 1
    }

    log "[成功] TLS 证书已准备好。"
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
        log "[失败] 找不到 Xray 程序。"
        return 1
    }

    key_output="$(get_xray_reality_keys "$xray")" || return 1
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
        --arg settings "$settings" \
        --arg stream "$stream" \
        --arg sniff "$sniff" \
        '{
          enable:true,remark:$remark,listen:"",port:$port,protocol:"vless",
          settings:$settings,streamSettings:$stream,sniffing:$sniff,
          total:0,expiryTime:0
        }')" || return 1

    api_post add "$body" >/dev/null || return 1

    printf 'vless://%s@%s:%s?encryption=none&security=reality&sni=www.microsoft.com&fp=chrome&pbk=%s&sid=%s&type=tcp&flow=xtls-rprx-vision#%s\n' \
        "$uuid" "$ip" "$port" "$public" "$short" "$remark" \
        >> "$DATA/nodes.txt"

    open_ufw_port_if_active "$port"
    log "[成功] REALITY 入站已提交给 3x-ui。"
}

create_tls() {
    local domain="$1" port="$2"
    local uuid remark settings stream sniff body

    uuid="$(cat /proc/sys/kernel/random/uuid)"
    remark="ZT-VLESS-TLS"

    settings="$(jq -cn --arg id "$uuid" \
        '{clients:[{id:$id,email:$id}],decryption:"none"}')" || return 1

    stream="$(jq -cn \
        --arg domain "$domain" \
        --arg cert "/etc/letsencrypt/live/$domain/fullchain.pem" \
        --arg key "/etc/letsencrypt/live/$domain/privkey.pem" \
        '{
          network:"tcp",
          security:"tls",
          tlsSettings:{
            serverName:$domain,
            minVersion:"1.2",
            certificates:[{
              certificateFile:$cert,
              keyFile:$key,
              ocspStapling:3600
            }],
            alpn:["http/1.1"]
          }
        }')" || return 1

    sniff='{"enabled":true,"destOverride":["http","tls"]}'

    body="$(jq -cn \
        --arg remark "$remark" \
        --argjson port "$port" \
        --arg settings "$settings" \
        --arg stream "$stream" \
        --arg sniff "$sniff" \
        '{
          enable:true,remark:$remark,listen:"",port:$port,protocol:"vless",
          settings:$settings,streamSettings:$stream,sniffing:$sniff,
          total:0,expiryTime:0
        }')" || return 1

    api_post add "$body" >/dev/null || return 1

    printf 'vless://%s@%s:%s?encryption=none&security=tls&sni=%s&fp=chrome&type=tcp#%s\n' \
        "$uuid" "$domain" "$port" "$domain" "$remark" \
        >> "$DATA/nodes.txt"

    open_ufw_port_if_active "$port"
    log "[成功] VLESS TLS 入站已提交给 3x-ui。"
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
        --arg settings "$settings" \
        --arg stream "$stream" \
        --arg sniff "$sniff" \
        '{
          enable:true,remark:$remark,listen:"",port:$port,protocol:"vmess",
          settings:$settings,streamSettings:$stream,sniffing:$sniff,
          total:0,expiryTime:0
        }')" || return 1

    api_post add "$body" >/dev/null || return 1

    vmess_json="$(jq -cn \
        --arg add "$ip" --arg port "$port" --arg id "$uuid" --arg ps "$remark" \
        '{
          v:"2",ps:$ps,add:$add,port:$port,id:$id,aid:"0",
          scy:"auto",net:"tcp",type:"none",host:"",path:"",tls:""
        }')" || return 1

    encoded="$(printf '%s' "$vmess_json" | base64 -w0)" || return 1
    printf 'vmess://%s\n' "$encoded" >> "$DATA/nodes.txt"

    open_ufw_port_if_active "$port"
    log "[成功] VMess TCP 入站已提交给 3x-ui。"
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
        --arg settings "$settings" \
        --arg stream "$stream" \
        --arg sniff "$sniff" \
        '{
          enable:true,remark:$remark,listen:"",port:$port,protocol:"shadowsocks",
          settings:$settings,streamSettings:$stream,sniffing:$sniff,
          total:0,expiryTime:0
        }')" || return 1

    api_post add "$body" >/dev/null || return 1

    userinfo="$(printf '%s' "$method:$password" | base64 -w0)" || return 1
    printf 'ss://%s@%s:%s#%s\n' \
        "$userinfo" "$ip" "$port" "$remark" >> "$DATA/nodes.txt"

    open_ufw_port_if_active "$port"
    log "[成功] Shadowsocks 入站已提交给 3x-ui。"
}

# ------------------------------------------------------------
# 订阅服务
# ------------------------------------------------------------

install_subscription_server() {
    local port="$1"
    SUB_PORT="$port"

    mkdir -p "$BASE" "$DATA"
    chmod 700 "$BASE" "$DATA"

    if [[ ! -s "$TOKEN_FILE" ]]; then
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

        try:
            raw = (DATA / "nodes.txt").read_bytes()
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

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload || return 1
    systemctl enable "$SERVICE" >/dev/null 2>&1 || return 1
    systemctl restart "$SERVICE" || return 1

    sleep 1

    systemctl is-active --quiet "$SERVICE" || {
        log "[失败] 订阅服务启动失败。"
        journalctl -u "$SERVICE" -n 40 --no-pager
        return 1
    }

    ss -H -lnt | awk -v p=":$SUB_PORT" \
        '$4 ~ (p "$") {found=1} END {exit !found}' || {
        fail "订阅端口 $SUB_PORT 没有监听。"
        return 1
    }

    open_ufw_port_if_active "$SUB_PORT"
}

verify_subscription() {
    local token tmp decoded

    [[ -s "$DATA/nodes.txt" ]] || {
        fail "节点文件为空。"
        return 1
    }

    token="$(cat "$TOKEN_FILE")" || return 1
    tmp="$(mktemp)"
    decoded="$(mktemp)"
    chmod 600 "$tmp" "$decoded"

    if ! curl -fsS --connect-timeout 3 --max-time 8 \
        "http://127.0.0.1:${SUB_PORT}/${token}" -o "$tmp"; then
        log "[修复] 订阅访问失败，尝试重启服务。"
        systemctl restart "$SERVICE" || true
        sleep 1

        if ! curl -fsS --connect-timeout 3 --max-time 8 \
            "http://127.0.0.1:${SUB_PORT}/${token}" -o "$tmp"; then
            rm -f "$tmp" "$decoded"
            fail "订阅服务重启后仍无法访问。"
            journalctl -u "$SERVICE" -n 40 --no-pager
            return 1
        fi
    fi

    if ! base64 -d "$tmp" > "$decoded" 2>/dev/null ||
       ! grep -qE '^(vless|vmess|ss)://' "$decoded"; then
        rm -f "$tmp" "$decoded"
        fail "订阅返回内容无效。"
        return 1
    fi

    rm -f "$tmp" "$decoded"
    log "[成功] 订阅本地访问与内容检查通过。"
}

# ------------------------------------------------------------
# 节点端口和 Xray 状态检查
# ------------------------------------------------------------

remove_last_generated_node() {
    # 当前部署流程串行执行；监听验证失败时，删除刚刚生成的最后一条节点，
    # 避免把本机都未监听的节点放进订阅，导致客户端测速失败（-1）。
    if [[ -s "$DATA/nodes.txt" ]]; then
        sed -i '$d' "$DATA/nodes.txt"
        log "[清理] 已从订阅中移除监听验证失败的节点。"
    fi
}

verify_inbound_port() {
    local port="$1"
    local i tcp_found=0 udp_found=0

    # 3x-ui 的 API 返回成功后，Xray 重载配置可能仍需要数秒。
    # 最多等待 20 秒，避免重载窗口内过早判定失败。
    for i in $(seq 1 20); do
        if ss -H -lnt 2>/dev/null | awk -v p=":$port" '$4 ~ (p "$") {found=1} END {exit !found}'; then
            log "[成功] TCP 端口 $port 正在监听。"
            return 0
        fi
        sleep 1
    done

    if ss -H -lnu 2>/dev/null | awk -v p=":$port" '$4 ~ (p "$") {found=1} END {exit !found}'; then
        udp_found=1
    fi

    log "[失败] 等待 20 秒后，仍未检测到 TCP 端口 $port 监听。"
    (( udp_found == 1 )) && log "[诊断] 发现 UDP $port，但该节点还需要 TCP 监听；UDP 存在不能视为节点可用。"
    log "[诊断] 当前相关监听："
    ss -H -lntup 2>/dev/null | awk -v p=":$port" '$0 ~ p {print "[端口] " $0}' | while IFS= read -r line; do log "$line"; done
    log "[诊断] 3x-ui 入站列表中对应端口/协议："
    if [[ -s "$COOKIE" && -s "$API_ROOT_FILE" ]]; then
        local root list
        root="$(cat "$API_ROOT_FILE")"
        list="$(curl -fsS --max-time 10 -b "$COOKIE" "${root}panel/api/inbounds/list" 2>/dev/null || true)"
        if jq -e '.success == true' >/dev/null 2>&1 <<< "$list"; then
            jq -r --argjson p "$port" '.obj[]? | select((.port|tonumber)==$p) | "[入站] id=\(.id // "?") protocol=\(.protocol // "?") enable=\(.enable // false) remark=\(.remark // "")"' <<< "$list" | while IFS= read -r line; do log "$line"; done
            if ! jq -e --argjson p "$port" '.obj[]? | select((.port|tonumber)==$p)' >/dev/null <<< "$list"; then
                log "[诊断] API 入站列表中未找到端口 $port；请检查 API 写入结果。"
            fi
        else
            log "[诊断] 无法读取 API 入站列表。"
        fi
    fi
    log "[诊断] 最近 60 行 x-ui 日志："
    journalctl -u x-ui -n 60 --no-pager 2>/dev/null | while IFS= read -r line; do log "[x-ui] $line"; done
    log "[诊断] 不自动重启 x-ui，以免中断服务器上已有节点。"
    return 1
}

# ------------------------------------------------------------
# 部署主流程
# ------------------------------------------------------------

deploy_all() {
    need_root || return 1
    install_dependencies || return 1
    install_xui || return 1
    api_login || return 1

    local ip p1 p2 p3 tls_port sub_port
    local success=0 failed=0
    local use_tls=0 tls_domain=""

    ip="$(get_public_ip)" || {
        fail "无法获取公网 IPv4。"
        return 1
    }

    echo
    echo "[信息] 公网 IPv4：$ip"

    if ask_domain_mode; then
        use_tls="$USE_TLS"
        tls_domain="$TLS_DOMAIN"
    else
        log "[警告] 域名配置无效或读取失败，本轮跳过 TLS 节点。"
    fi

    p1="$(choose_port 24443 18443 14443 10443)" || p1=""
    p2="$(choose_port 23456 23457 23458 23459)" || p2=""
    p3="$(choose_port 23888 23889 23890 23891)" || p3=""

    # TLS 端口优先 443；占用时自动尝试备用端口。
    tls_port=""
    if (( use_tls == 1 )); then
        if ! obtain_tls_certificate "$tls_domain"; then
            log "[警告] TLS 证书不可用，本轮跳过 TLS 节点。"
            use_tls=0
        else
            tls_port="$(choose_port 443 8443 2053 9443 10443)" || tls_port=""
            if [[ -z "$tls_port" ]]; then
                log "[失败] 443 和所有备用 TLS 端口均被占用。"
                log "[提示] 不会停止或杀死占用端口的服务。"
                use_tls=0
            elif [[ "$tls_port" != "443" ]]; then
                log "[信息] 443 已被占用，TLS 节点将使用备用端口 $tls_port。"
            fi
        fi
    fi

    if [[ -z "$p1" ]]; then log "[警告] 无可用 REALITY 端口。"; fi
    if [[ -z "$p2" ]]; then log "[警告] 无可用 VMess 端口。"; fi
    if [[ -z "$p3" ]]; then log "[警告] 无可用 Shadowsocks 端口。"; fi

    # 订阅服务优先复用原端口；若端口被占用则寻找备用端口。
    sub_port="$(choose_port "$SUB_PORT" 18889 18890 18891)" || {
        fail "找不到可用订阅端口。"
        return 1
    }
    SUB_PORT="$sub_port"

    : > "$DATA/nodes.txt"
    : > "$RESULT_FILE"
    chmod 600 "$DATA/nodes.txt" "$RESULT_FILE"

    if [[ -n "$p1" ]]; then
        if create_reality "$ip" "$p1"; then
            if verify_inbound_port "$p1"; then
                echo "VLESS REALITY：已创建，端口 $p1；监听检查通过" | tee -a "$RESULT_FILE"
                success=$((success + 1))
            else
                echo "VLESS REALITY：已创建，但监听检查失败，端口 $p1" | tee -a "$RESULT_FILE"
                remove_last_generated_node
                failed=$((failed + 1))
            fi
        else
            echo "VLESS REALITY：创建失败" | tee -a "$RESULT_FILE"
            failed=$((failed + 1))
        fi
    else
        echo "VLESS REALITY：没有可用端口" | tee -a "$RESULT_FILE"
        failed=$((failed + 1))
    fi

    if (( use_tls == 1 )) && [[ -n "$tls_port" ]]; then
        if create_tls "$tls_domain" "$tls_port"; then
            if verify_inbound_port "$tls_port"; then
                echo "VLESS TLS：已创建，端口 $tls_port；监听检查通过" | tee -a "$RESULT_FILE"
                success=$((success + 1))
            else
                echo "VLESS TLS：已创建，但监听检查失败，端口 $tls_port" | tee -a "$RESULT_FILE"
                remove_last_generated_node
                failed=$((failed + 1))
            fi
        else
            echo "VLESS TLS：创建失败" | tee -a "$RESULT_FILE"
            failed=$((failed + 1))
        fi
    elif (( use_tls == 1 )); then
        echo "VLESS TLS：无可用端口" | tee -a "$RESULT_FILE"
        failed=$((failed + 1))
    else
        echo "VLESS TLS：已跳过" | tee -a "$RESULT_FILE"
    fi

    if [[ -n "$p2" ]]; then
        if create_vmess "$ip" "$p2"; then
            if verify_inbound_port "$p2"; then
                echo "VMess TCP：已创建，端口 $p2；监听检查通过" | tee -a "$RESULT_FILE"
                success=$((success + 1))
            else
                echo "VMess TCP：已创建，但监听检查失败，端口 $p2" | tee -a "$RESULT_FILE"
                remove_last_generated_node
                failed=$((failed + 1))
            fi
        else
            echo "VMess TCP：创建失败" | tee -a "$RESULT_FILE"
            failed=$((failed + 1))
        fi
    else
        echo "VMess TCP：没有可用端口" | tee -a "$RESULT_FILE"
        failed=$((failed + 1))
    fi

    if [[ -n "$p3" ]]; then
        if create_shadowsocks "$ip" "$p3"; then
            if verify_inbound_port "$p3"; then
                echo "Shadowsocks：已创建，端口 $p3；监听检查通过" | tee -a "$RESULT_FILE"
                success=$((success + 1))
            else
                echo "Shadowsocks：已创建，但监听检查失败，端口 $p3" | tee -a "$RESULT_FILE"
                remove_last_generated_node
                failed=$((failed + 1))
            fi
        else
            echo "Shadowsocks：创建失败" | tee -a "$RESULT_FILE"
            failed=$((failed + 1))
        fi
    else
        echo "Shadowsocks：没有可用端口" | tee -a "$RESULT_FILE"
        failed=$((failed + 1))
    fi

    if [[ ! -s "$DATA/nodes.txt" ]]; then
        fail "没有生成任何节点，不发布空订阅。"
        return 1
    fi

    install_subscription_server "$SUB_PORT" || {
        fail "订阅服务启动失败。"
        return 1
    }

    verify_subscription || {
        fail "订阅检查失败。"
        return 1
    }

    local token
    token="$(cat "$TOKEN_FILE")"

    echo
    echo "============================================================"
    echo "                   部署结果汇总"
    echo "============================================================"
    echo "公网 IPv4：$ip"
    echo
    cat "$RESULT_FILE"
    echo
    echo "生成节点数：$(grep -cE '^(vless|vmess|ss)://' "$DATA/nodes.txt" || true)"
    echo "订阅地址：http://${ip}:${SUB_PORT}/${token}"

    if (( use_tls == 1 )) && [[ -n "$tls_port" ]]; then
        echo "TLS 域名：$tls_domain"
        echo "TLS 端口：$tls_port"
    fi

    echo
    echo "节点文件：$DATA/nodes.txt"
    echo "结果文件：$RESULT_FILE"
    echo "日志文件：$LOG"
    echo
    echo "[注意] 必须在云服务商安全组放行实际使用的节点端口和订阅端口。"
    echo "[注意] TLS 证书申请成功不等于 TLS 节点外网可连接。"
    echo "[注意] 监听检查通过也不代表客户端测速一定成功。"
    echo "============================================================"

    log "[完成] 节点生成流程结束：成功 $success，失败 $failed。"
    return 0
}

# ------------------------------------------------------------
# 菜单
# ------------------------------------------------------------

show_menu() {
    echo
    echo "============================================================"
    echo "               瞎折腾吧 | VPS 节点管理器"
    echo "============================================================"
    echo "  1. 一键部署 / 自动修复 / 检查节点"
    echo "  2. 查看 3x-ui 状态"
    echo "  3. 查看订阅节点"
    echo "  4. 查看部署结果"
    echo "  5. 查看最近日志"
    echo "  6. 重启 3x-ui"
    echo "  7. 重启订阅服务"
    echo "  8. 重新配置面板登录信息"
    echo "  0. 退出"
    echo "============================================================"
}

main() {
    need_root || exit 1

    while true; do
        show_menu

        local choice
        read -r -p "请选择 [0-8]：" choice </dev/tty || {
            echo "[错误] 无法读取终端输入。"
            exit 1
        }

        case "$choice" in
            1)
                deploy_all || echo "[警告] 部署存在失败项目，请查看 $LOG"
                pause
                ;;
            2)
                systemctl --no-pager --full status x-ui || true
                pause
                ;;
            3)
                if [[ -s "$DATA/nodes.txt" ]]; then
                    cat "$DATA/nodes.txt"
                else
                    echo "暂无节点。"
                fi
                pause
                ;;
            4)
                if [[ -s "$RESULT_FILE" ]]; then
                    cat "$RESULT_FILE"
                else
                    echo "暂无部署结果。"
                fi
                pause
                ;;
            5)
                tail -n 100 "$LOG" || true
                pause
                ;;
            6)
                if systemctl restart x-ui; then
                    echo "[成功] 已发送重启请求。"
                else
                    echo "[失败] 3x-ui 重启失败。"
                fi
                pause
                ;;
            7)
                if systemctl restart "$SERVICE"; then
                    echo "[成功] 已发送订阅服务重启请求。"
                else
                    echo "[失败] 订阅服务重启失败。"
                    journalctl -u "$SERVICE" -n 40 --no-pager || true
                fi
                pause
                ;;
            8)
                rm -f "$ENV_FILE" "$COOKIE" "$API_ROOT_FILE"
                read_credentials || echo "[失败] 配置更新失败。"
                pause
                ;;
            0)
                echo "已退出。"
                exit 0
                ;;
            *)
                echo "[错误] 无效选项。"
                ;;
        esac
    done
}

main "$@"
