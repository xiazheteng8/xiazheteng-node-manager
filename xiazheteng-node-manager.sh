
#!/usr/bin/env bash
# 瞎折腾吧 | VPS 一键节点部署器
# Ubuntu 22.04 / Debian
# 当前自动部署协议：VLESS REALITY、VMess TCP、Shadowsocks

set -uo pipefail
umask 077

APP="xiazheteng-node-manager"
BASE="/opt/$APP"
DATA="$BASE/data"
ENV_FILE="$BASE/config.env"
SUB_TOKEN_FILE="$BASE/subscription.token"
SUB_PORT=18888
LOG="/var/log/$APP.log"

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
        echo "请使用 root 运行。"
        exit 1
    fi
}

install_dependencies() {
    export DEBIAN_FRONTEND=noninteractive
    apt-get update || return 1
    apt-get install -y curl ca-certificates jq openssl python3 iproute2 uuid-runtime || return 1
    command -v curl >/dev/null &&
    command -v jq >/dev/null &&
    command -v openssl >/dev/null &&
    command -v python3 >/dev/null
}

get_public_ip() {
    local ip
    ip="$(curl -4 -fsS --connect-timeout 5 --max-time 10 https://api.ipify.org 2>/dev/null || true)"
    if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        printf '%s' "$ip"
    else
        printf ''
    fi
}

port_free() {
    ! ss -H -lnt "( sport = :$1 )" 2>/dev/null | grep -q .
}

choose_port() {
    local p
    for p in "$@"; do
        if port_free "$p"; then
            printf '%s' "$p"
            return 0
        fi
    done
    return 1
}

detect_xui() {
    command -v x-ui >/dev/null 2>&1 ||
    [[ -x /usr/local/x-ui/x-ui ]] ||
    systemctl list-unit-files --no-legend 2>/dev/null |
        awk '{print $1}' | grep -qx 'x-ui.service'
}

install_xui() {
    if detect_xui; then
        log "[信息] 检测到已有 3x-ui，保留现有安装。"
        return 0
    fi

    log "[信息] 正在运行 3x-ui 官方无人值守安装程序..."
    XUI_NONINTERACTIVE=1 bash <(
        curl -4 -fsSL --retry 3 \
          https://raw.githubusercontent.com/MHSanaei/3x-ui/master/install.sh
    ) || {
        fail "3x-ui 官方安装程序失败。"
        return 1
    }

    systemctl enable --now x-ui || return 1
    systemctl is-active --quiet x-ui || {
        fail "3x-ui 服务未正常启动。"
        return 1
    }

    log "[成功] 3x-ui 已安装并运行。"
}

read_credentials() {
    local result="/etc/x-ui/install-result.env"

    echo
    echo "需要面板 API 登录凭据。"
    echo "新安装时请使用官方安装程序生成的凭据；已有面板请使用当前凭据。"

    if [[ -f "$result" ]]; then
        echo "官方安装结果文件存在：$result"
        echo "请查看其中的变量名称和实际字段，勿将密码发给他人。"
    fi

    read -r -p "面板用户名：" XUI_USER </dev/tty
    read -r -s -p "面板密码：" XUI_PASS </dev/tty
    echo
    read -r -p "面板端口 [默认 2053]：" XUI_PORT </dev/tty
    XUI_PORT="${XUI_PORT:-2053}"
    read -r -p "面板 Web 路径（例如 /abc123/）：" XUI_PATH </dev/tty

    [[ "$XUI_PORT" =~ ^[0-9]+$ ]] || {
        fail "面板端口格式不正确。"
        return 1
    }

    [[ "$XUI_PATH" == /* && "$XUI_PATH" == */ ]] || {
        fail "Web 路径必须以 / 开始并以 / 结束。"
        return 1
    }

    cat > "$ENV_FILE" <<EOF
XUI_USER=$(printf '%q' "$XUI_USER")
XUI_PASS=$(printf '%q' "$XUI_PASS")
XUI_PORT=$(printf '%q' "$XUI_PORT")
XUI_PATH=$(printf '%q' "$XUI_PATH")
EOF
    chmod 600 "$ENV_FILE"
}

api_login() {
    source "$ENV_FILE"

    local root="http://127.0.0.1:${XUI_PORT}${XUI_PATH}"
    local csrf response

    COOKIE="$BASE/cookie.txt"
    rm -f "$COOKIE"

    csrf="$(curl -fsS --max-time 10 "$root/csrf-token" 2>/dev/null |
        jq -r '.obj // empty' || true)"

    local -a headers=()
    [[ -n "$csrf" ]] && headers=(-H "X-CSRF-Token: $csrf")

    response="$(curl -sS --max-time 15 \
        -c "$COOKIE" -b "$COOKIE" \
        -H 'Content-Type: application/json' \
        "${headers[@]}" \
        -d "$(jq -n --arg u "$XUI_USER" --arg p "$XUI_PASS" \
            '{username:$u,password:$p}')" \
        "$root/login" 2>/dev/null || true)"

    if ! jq -e '.success == true' >/dev/null 2>&1 <<<"$response"; then
        fail "面板 API 登录失败。请确认用户名、密码、端口和 Web 路径。"
        return 1
    fi

    echo "$root" > "$BASE/api-root"
    chmod 600 "$COOKIE" "$BASE/api-root"
    log "[成功] 面板 API 登录成功。"
}

api_post() {
    local endpoint="$1" body="$2"
    local root csrf response

    root="$(cat "$BASE/api-root")"
    csrf="$(curl -fsS -b "$COOKIE" "$root/csrf-token" 2>/dev/null |
        jq -r '.obj // empty' || true)"

    response="$(curl -sS --max-time 20 \
        -b "$COOKIE" -c "$COOKIE" \
        -H 'Content-Type: application/json' \
        ${csrf:+-H "X-CSRF-Token: $csrf"} \
        -d "$body" \
        "${root}panel/api/inbounds/$endpoint" 2>/dev/null || true)"

    if ! jq -e '.success == true' >/dev/null 2>&1 <<<"$response"; then
        log "[失败] API 请求 $endpoint 失败：$response"
        return 1
    fi
    printf '%s' "$response"
}

create_reality() {
    local ip="$1" port="$2"
    local uuid private public short remark body settings stream sniff response

    uuid="$(cat /proc/sys/kernel/random/uuid)"
    remark="ZT-VLESS-REALITY"
    short="$(openssl rand -hex 8)"

    local xray
    xray="$(find /usr/local/x-ui /usr/local/bin -type f -name 'xray*' 2>/dev/null | head -n1)"
    [[ -x "$xray" ]] || {
        fail "没有找到可执行的 Xray 程序。"
        return 1
    }

    local keys
    keys="$("$xray" x25519 2>/dev/null || true)"
    private="$(awk -F': *' '/PrivateKey:/ {print $2; exit}' <<<"$keys")"
    public="$(awk -F': *' '/Password:/ {print $2; exit}' <<<"$keys")"
    [[ -n "$public" ]] || public="$(awk -F': *' '/PublicKey:/ {print $2; exit}' <<<"$keys")"

    [[ -n "$private" && -n "$public" ]] || {
        fail "无法识别当前 Xray 的 x25519 输出格式。"
        return 1
    }

    settings="$(jq -cn --arg id "$uuid" \
        '{clients:[{id:$id,flow:"xtls-rprx-vision",email:$id}],decryption:"none"}')"

    stream="$(jq -cn --arg pk "$private" --arg sid "$short" \
        '{network:"tcp",security:"reality",realitySettings:{show:false,
        dest:"www.microsoft.com:443",xver:0,
        serverNames:["www.microsoft.com"],privateKey:$pk,
        shortIds:[$sid]}}')"

    sniff='{"enabled":true,"destOverride":["http","tls","quic"]}'

    body="$(jq -cn \
        --arg remark "$remark" \
        --argjson port "$port" \
        --arg settings "$settings" \
        --arg stream "$stream" \
        --arg sniff "$sniff" \
        '{enable:true,remark:$remark,port:$port,protocol:"vless",
        settings:$settings,streamSettings:$stream,sniffing:$sniff,
        total:0,expiryTime:0}')"

    response="$(api_post add "$body")" || return 1

    printf 'vless://%s@%s:%s?encryption=none&security=reality&sni=www.microsoft.com&fp=chrome&pbk=%s&sid=%s&type=tcp&flow=xtls-rprx-vision#%s\n' \
        "$uuid" "$ip" "$port" "$public" "$short" "$remark" >> "$DATA/nodes.txt"

    log "[成功] VLESS REALITY 入站已由面板 API 接受。"
}

create_vmess() {
    local ip="$1" port="$2"
    local uuid remark settings stream sniff body vmess_json encoded

    uuid="$(cat /proc/sys/kernel/random/uuid)"
    remark="ZT-VMESS-TCP"

    settings="$(jq -cn --arg id "$uuid" \
        '{clients:[{id:$id,alterId:0,email:$id}],disableInsecureEncryption:false}')"
    stream='{"network":"tcp","security":"none"}'
    sniff='{"enabled":true,"destOverride":["http","tls"]}'

    body="$(jq -cn --arg remark "$remark" --argjson port "$port" \
        --arg settings "$settings" --arg stream "$stream" --arg sniff "$sniff" \
        '{enable:true,remark:$remark,port:$port,protocol:"vmess",
        settings:$settings,streamSettings:$stream,sniffing:$sniff,
        total:0,expiryTime:0}')"

    api_post add "$body" >/dev/null || return 1

    vmess_json="$(jq -cn --arg add "$ip" --arg port "$port" --arg id "$uuid" \
        --arg ps "$remark" \
        '{v:"2",ps:$ps,add:$add,port:$port,id:$id,aid:"0",scy:"auto",
        net:"tcp",type:"none",host:"",path:"",tls:""}')"
    encoded="$(printf '%s' "$vmess_json" | base64 -w0)"

    printf 'vmess://%s\n' "$encoded" >> "$DATA/nodes.txt"
    log "[成功] VMess TCP 入站已由面板 API 接受。"
}

create_shadowsocks() {
    local ip="$1" port="$2"
    local password method remark settings stream sniff body userinfo encoded

    password="$(openssl rand -base64 24 | tr -d '\n')"
    method="aes-128-gcm"
    remark="ZT-SHADOWSOCKS"

    settings="$(jq -cn --arg p "$password" --arg m "$method" \
        '{method:$m,password:$p,network:"tcp,udp",clients:[]}')"
    stream='{"network":"tcp","security":"none"}'
    sniff='{"enabled":true,"destOverride":["http","tls"]}'

    body="$(jq -cn --arg remark "$remark" --argjson port "$port" \
        --arg settings "$settings" --arg stream "$stream" --arg sniff "$sniff" \
        '{enable:true,remark:$remark,port:$port,protocol:"shadowsocks",
        settings:$settings,streamSettings:$stream,sniffing:$sniff,
        total:0,expiryTime:0}')"

    api_post add "$body" >/dev/null || return 1

    userinfo="$(printf '%s' "$method:$password" | base64 -w0)"
    printf 'ss://%s@%s:%s#%s\n' "$userinfo" "$ip" "$port" "$remark" >> "$DATA/nodes.txt"
    log "[成功] Shadowsocks 入站已由面板 API 接受。"
}

install_subscription_server() {
    local token
    token="$(openssl rand -hex 24)"
    printf '%s' "$token" > "$SUB_TOKEN_FILE"
    chmod 600 "$SUB_TOKEN_FILE"

    cat > "$BASE/subscription-server.py" <<'PYEOF'
#!/usr/bin/env python3
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import base64

base = Path("/opt/xiazheteng-node-manager/data")
token_file = Path("/opt/xiazheteng-node-manager/subscription.token")

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        token = token_file.read_text().strip()
        if self.path != "/" + token:
            self.send_error(404)
            return
        nodes = base.joinpath("nodes.txt")
        if not nodes.exists():
            self.send_error(503, "Subscription not ready")
            return
        payload = base64.b64encode(nodes.read_bytes())
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, fmt, *args):
        pass

ThreadingHTTPServer(("0.0.0.0", 18888), Handler).serve_forever()
PYEOF

    chmod 700 "$BASE/subscription-server.py"

    cat > /etc/systemd/system/xiazheteng-subscription.service <<EOF
[Unit]
Description=Xiazheteng Node Subscription
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 $BASE/subscription-server.py
Restart=on-failure
RestartSec=3
User=root
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ReadWritePaths=$BASE

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now xiazheteng-subscription.service || return 1
}

deploy_all() {
    need_root || return 1
    install_dependencies || {
        fail "依赖安装失败。"
        return 1
    }

    install_xui || return 1

    if [[ ! -f "$ENV_FILE" ]]; then
        read_credentials || return 1
    fi

    api_login || return 1

    local ip p1 p2 p3
    ip="$(get_public_ip)"
    [[ -n "$ip" ]] || {
        fail "无法获取公网 IPv4。"
        return 1
    }

    p1="$(choose_port 24443 18443 14443 10443)" || {
        fail "没有找到可用的 VLESS REALITY 端口。"
        return 1
    }
    p2="$(choose_port 23456 23457 23458 23459)" || {
        fail "没有找到可用的 VMess 端口。"
        return 1
    }
    p3="$(choose_port 23888 23889 23890 23891)" || {
        fail "没有找到可用的 Shadowsocks 端口。"
        return 1
    }

    : > "$DATA/nodes.txt"
    create_reality "$ip" "$p1" || return 1
    create_vmess "$ip" "$p2" || return 1
    create_shadowsocks "$ip" "$p3" || return 1

    install_subscription_server || {
        fail "订阅服务安装失败。"
        return 1
    }

    local token url
    token="$(cat "$SUB_TOKEN_FILE")"
    url="http://$ip:$SUB_PORT/$token"

    echo
    echo "================ 部署结果 ================"
    echo "公网 IPv4：$ip"
    echo "VLESS REALITY 端口：$p1"
    echo "VMess TCP 端口：$p2"
    echo "Shadowsocks 端口：$p3"
    echo
    echo "统一订阅链接："
    echo "$url"
    echo
    echo "节点文件：$DATA/nodes.txt"
    echo "管理器日志：$LOG"
    echo
    echo "[重要] 请在云服务商防火墙放行以上三个节点端口及 TCP $SUB_PORT。"
    echo "[重要] 当前订阅服务使用 HTTP；生产环境建议通过已有 HTTPS 反向代理保护订阅链接。"
    echo "=========================================="
}

show_menu() {
    echo
    echo "============================================================"
    echo "       瞎折腾吧 | VPS 一键节点部署器"
    echo "============================================================"
    echo "  1. 一键安装 / 检查 / 部署节点"
    echo "  2. 查看 3x-ui 状态"
    echo "  3. 查看已生成节点"
    echo "  4. 查看日志"
    echo "  5. 重启 3x-ui"
    echo "  6. 重启订阅服务"
    echo "  0. 退出"
    echo "============================================================"
}

main() {
    need_root || exit 1
    while true; do
        show_menu
        local choice
        read -r -p "请选择：" choice </dev/tty || {
            echo "[错误] 无法读取终端输入。"
            exit 1
        }

        case "$choice" in
            1) deploy_all; pause ;;
            2) systemctl --no-pager --full status x-ui || true; pause ;;
            3) cat "$DATA/nodes.txt" 2>/dev/null || echo "尚未生成节点"; pause ;;
            4) tail -n 100 "$LOG"; pause ;;
            5) systemctl restart x-ui && echo "已重启" || echo "重启失败"; pause ;;
            6) systemctl restart xiazheteng-subscription.service && echo "已重启" || echo "重启失败"; pause ;;
            0) echo "已退出"; exit 0 ;;
            *) echo "无效选项，请输入 0-6。" ;;
        esac
    done
}

main "$@"
