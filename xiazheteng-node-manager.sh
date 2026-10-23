
#!/usr/bin/env bash
# ============================================================
# 瞎折腾吧 | VPS 自动部署管理器
# 3x-ui + Xray + 多协议节点 + 独立订阅服务
# 目标系统：Debian / Ubuntu
# ============================================================

set -Eeuo pipefail
umask 077

APP="xiazheteng-vps"
ROOT="/opt/${APP}"
LOG="/var/log/${APP}.log"
DATA="${ROOT}/data"
LINKS="${DATA}/links.txt"
SUBSCRIPT="${ROOT}/subscription_server.py"
SERVICE="/etc/systemd/system/${APP}-subscription.service"
OFFICIAL="https://raw.githubusercontent.com/MHSanaei/3x-ui/main/install.sh"

mkdir -p "$ROOT" "$DATA"
chmod 700 "$ROOT" "$DATA"
touch "$LOG"
chmod 600 "$LOG"
exec > >(tee -a "$LOG") 2>&1

info(){ echo "[信息] $*"; }
ok(){ echo "[成功] $*"; }
warn(){ echo "[警告] $*"; }
die(){ echo "[错误] $*" >&2; exit 1; }

trap 'rc=$?; echo "[错误] 第 ${LINENO} 行失败，退出码 ${rc}；日志：'"$LOG" >&2; exit "$rc"' ERR

[[ $EUID -eq 0 ]] || die "请以 root 身份运行。"
[[ -t 0 ]] || die "首次运行需要终端。请在 SSH 终端执行。"

source /etc/os-release
case "${ID:-}" in
  debian|ubuntu|armbian) ;;
  *) die "当前脚本仅自动处理 Debian、Ubuntu、Armbian。" ;;
esac

export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y curl ca-certificates openssl python3 python3-venv \
  iproute2 util-linux sqlite3

# ------------------------------------------------------------
# 一次性输入
# ------------------------------------------------------------

while true; do
  read -r -p "绑定域名：" DOMAIN
  DOMAIN="${DOMAIN,,}"
  if [[ "$DOMAIN" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]]; then
    break
  fi
  warn "域名格式不正确。"
done

while true; do
  read -r -p "3x-ui 管理用户名：" USERNAME
  [[ "$USERNAME" =~ ^[a-zA-Z0-9_.-]{3,64}$ ]] && break
  warn "用户名只能包含字母、数字、点、下划线和连字符，长度 3–64。"
done

while true; do
  read -r -s -p "3x-ui 管理密码（至少 12 位）：" PASSWORD
  echo
  [[ ${#PASSWORD} -ge 12 && "$PASSWORD" != *$'\n'* ]] && break
  warn "密码至少需要 12 个字符。"
done

read -r -p "订阅令牌（留空自动生成）：" SUB_TOKEN
SUB_TOKEN="${SUB_TOKEN:-$(openssl rand -hex 24)}"
[[ "$SUB_TOKEN" =~ ^[a-zA-Z0-9_-]{24,128}$ ]] || die "订阅令牌格式错误。"

# 避免后续意外打印密码。
set +x

# ------------------------------------------------------------
# 基础函数
# ------------------------------------------------------------

random_port(){
  shuf -i 20000-55000 -n 1
}

free_port(){
  local p i
  for i in $(seq 1 300); do
    p="$(random_port)"
    if ! ss -H -lnt 2>/dev/null |
      awk '{print $4}' |
      grep -Eq "[:.]${p}$"; then
      echo "$p"
      return 0
    fi
  done
  return 1
}

random_hex(){
  openssl rand -hex "$1"
}

json_escape(){
  python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'
}

info "检查域名 DNS。"
python3 - "$DOMAIN" <<'PY' || warn "DNS 当前不可用；TLS 与域名连通性需要后续复查。"
import socket,sys
try:
    for item in sorted({x[4][0] for x in socket.getaddrinfo(sys.argv[1], None)}):
        print(item)
except Exception as e:
    print(e)
    sys.exit(1)
PY

IP4="$(curl -4 -fsS --max-time 8 https://api.ipify.org 2>/dev/null || true)"
IP6="$(curl -6 -fsS --max-time 8 https://api64.ipify.org 2>/dev/null || true)"
info "公网 IPv4：${IP4:-不可用}"
info "公网 IPv6：${IP6:-不可用}"

info "现有监听端口："
ss -lntup || true

PANEL_PORT="$(free_port)" || die "无法找到面板端口。"
SUB_PORT="$(free_port)" || die "无法找到订阅端口。"

# ------------------------------------------------------------
# 官方安装器：非交互模式
# ------------------------------------------------------------

WEB_PATH="$(random_hex 18)"
WEB_PATH="/${WEB_PATH}"

export XUI_NONINTERACTIVE=1
export XUI_USERNAME="$USERNAME"
export XUI_PASSWORD="$PASSWORD"
export XUI_PANEL_PORT="$PANEL_PORT"
export XUI_WEB_BASE_PATH="$WEB_PATH"
export XUI_SSL_MODE=none
export XUI_DOMAIN="$DOMAIN"

info "下载官方 3x-ui 安装器。"
INSTALLER="$(mktemp)"
curl -fL --retry 3 "$OFFICIAL" -o "$INSTALLER"
bash -n "$INSTALLER" || die "官方安装脚本语法检查失败。"

info "开始无人值守安装 3x-ui。"
bash "$INSTALLER"
rm -f "$INSTALLER"

[[ -f /etc/x-ui/install-result.env ]] ||
  die "官方安装器没有生成 install-result.env。"

# 官方结果文件由官方安装器生成，限制权限后读取。
chmod 600 /etc/x-ui/install-result.env
# shellcheck disable=SC1091
source /etc/x-ui/install-result.env

PANEL_PORT="${XUI_PANEL_PORT:-$PANEL_PORT}"
WEB_PATH="${XUI_WEB_BASE_PATH:-$WEB_PATH}"

systemctl enable x-ui
systemctl restart x-ui
sleep 3
systemctl is-active --quiet x-ui || die "3x-ui 服务未启动。"

# ------------------------------------------------------------
# API 登录
# ------------------------------------------------------------

COOKIE="${DATA}/cookies.txt"
API_BASE="http://127.0.0.1:${PANEL_PORT}${WEB_PATH}"

info "登录面板 API。"
LOGIN_CODE="$(
  curl -sS --max-time 15 \
    -c "$COOKIE" -o "${DATA}/login.json" \
    -w '%{http_code}' \
    -H "Host: ${DOMAIN}:${PANEL_PORT}" \
    -X POST "${API_BASE}/login" \
    --data-urlencode "username=${USERNAME}" \
    --data-urlencode "password=${PASSWORD}" || true
)"

if [[ "$LOGIN_CODE" != "200" ]]; then
  die "面板 API 登录失败（HTTP ${LOGIN_CODE}）。检查凭据、Web 路径和面板日志。"
fi

API_GET(){
  curl -fsS --max-time 20 \
    -b "$COOKIE" \
    -H "Host: ${DOMAIN}:${PANEL_PORT}" \
    "$1"
}

API_POST(){
  curl -fsS --max-time 30 \
    -b "$COOKIE" \
    -H "Host: ${DOMAIN}:${PANEL_PORT}" \
    -H "Content-Type: application/json" \
    -X POST "$1" \
    --data-binary "@${DATA}/payload.json"
}

# ------------------------------------------------------------
# 节点创建
# ------------------------------------------------------------

CREATED=0
: > "$LINKS"
chmod 600 "$LINKS"

new_uuid(){
  python3 -c 'import uuid; print(uuid.uuid4())'
}

add_inbound(){
  local name="$1" port="$2" proto="$3" settings="$4" stream="$5"
  local payload response

  python3 - "$name" "$port" "$proto" "$settings" "$stream" > "${DATA}/payload.json" <<'PY'
import json,sys
name,port,proto,settings,stream=sys.argv[1:]
obj={
 "enable":True,
 "remark":name,
 "listen":"",
 "port":int(port),
 "protocol":proto,
 "expiryTime":0,
 "total":0,
 "settings":json.loads(settings),
 "streamSettings":json.loads(stream),
 "sniffing":{"enabled":True,"destOverride":["http","tls"]}
}
print(json.dumps(obj))
PY

  response="$(API_POST "${API_BASE}/panel/api/inbounds/add")" || {
    warn "${name} API 请求失败。"
    return 1
  }

  if ! python3 -c '
import json,sys
d=json.load(sys.stdin)
sys.exit(0 if d.get("success") is True else 1)
' <<< "$response"; then
    warn "${name} 创建失败：$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("msg","未知错误"))' <<< "$response")"
    return 1
  fi

  ok "${name} 入站已被面板接受。"
  CREATED=$((CREATED+1))
}

# VLESS REALITY
VLESS_PORT="$(free_port)" || die "没有可用 VLESS 端口。"
VLESS_UUID="$(new_uuid)"
SHORT_ID="$(random_hex 8)"

XRAY_BIN="$(find /usr/local/x-ui -type f -name 'xray*' -perm /111 2>/dev/null | head -n1 || true)"
PRIVATE_KEY=""
PUBLIC_KEY=""

if [[ -n "$XRAY_BIN" ]]; then
  KEY_OUTPUT="$("$XRAY_BIN" x25519 2>/dev/null || true)"
  PRIVATE_KEY="$(sed -nE 's/^(Private key|PrivateKey):[[:space:]]*//p' <<< "$KEY_OUTPUT" | head -n1)"
  PUBLIC_KEY="$(sed -nE 's/^(Public key|Password|PublicKey):[[:space:]]*//p' <<< "$KEY_OUTPUT" | head -n1)"
fi

if [[ -n "$PRIVATE_KEY" && -n "$PUBLIC_KEY" ]]; then
  SETTINGS="$(python3 - "$VLESS_UUID" <<'PY'
import json,sys
print(json.dumps({"clients":[{"id":sys.argv[1],"email":"auto-vless"}],"decryption":"none","fallbacks":[]}))
PY
)"
  STREAM="$(python3 - "$PRIVATE_KEY" "$SHORT_ID" <<'PY'
import json,sys
print(json.dumps({
 "network":"tcp","security":"reality",
 "realitySettings":{
  "show":False,"dest":"www.microsoft.com:443",
  "xver":0,"serverNames":["www.microsoft.com"],
  "privateKey":sys.argv[1],"shortIds":[sys.argv[2]]
 }
}))
PY
)"
  if add_inbound "AUTO-VLESS-REALITY" "$VLESS_PORT" "vless" "$SETTINGS" "$STREAM"; then
    printf '%s\n' "$VLESS_UUID" > "${DATA}/vless_uuid"
    printf '%s\n' "$PUBLIC_KEY" > "${DATA}/reality_public_key"
    printf '%s\n' "$SHORT_ID" > "${DATA}/reality_short_id"
  fi
else
  warn "无法从 Xray 获取 REALITY 密钥，跳过该节点。"
fi

# VMess TCP
VMESS_PORT="$(free_port)" || die "没有可用 VMess 端口。"
VMESS_UUID="$(new_uuid)"
VMESS_SETTINGS="$(python3 - "$VMESS_UUID" <<'PY'
import json,sys
print(json.dumps({"clients":[{"id":sys.argv[1],"alterId":0,"email":"auto-vmess"}]}))
PY
)"
VMESS_STREAM='{"network":"tcp","security":"none","tcpSettings":{"acceptProxyProtocol":false,"header":{"type":"none"}}}'

add_inbound "AUTO-VMESS-TCP" "$VMESS_PORT" "vmess" "$VMESS_SETTINGS" "$VMESS_STREAM" || true

# Shadowsocks
SS_PORT="$(free_port)" || die "没有可用 Shadowsocks 端口。"
SS_PASSWORD="$(random_hex 18)"
SS_SETTINGS="$(python3 - "$SS_PASSWORD" <<'PY'
import json,sys
print(json.dumps({"method":"aes-128-gcm","password":sys.argv[1],"network":"tcp,udp"}))
PY
)"
SS_STREAM='{"network":"tcp","security":"none"}'

add_inbound "AUTO-SHADOWSOCKS" "$SS_PORT" "shadowsocks" "$SS_SETTINGS" "$SS_STREAM" || true

# ------------------------------------------------------------
# 读取实际创建结果和分享链接
# ------------------------------------------------------------

info "读取面板实际入站列表。"
API_GET "${API_BASE}/panel/api/inbounds/list" > "${DATA}/inbounds.json"

python3 - "$DATA/inbounds.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
if not d.get("success"):
    raise SystemExit("面板没有成功返回入站列表")
items=d.get("obj") or []
print("当前面板入站数量：",len(items))
for item in items:
    print("ID:",item.get("id"),"协议:",item.get("protocol"),"端口:",item.get("port"),"启用:",item.get("enable"))
PY

API_GET "${API_BASE}/panel/api/inbounds/allLinks" > "${DATA}/allLinks.json"

python3 - "$DATA/allLinks.json" "$LINKS" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
if not d.get("success"):
    raise SystemExit("无法获取真实分享链接："+str(d.get("msg","")))
links=d.get("obj") or []
with open(sys.argv[2],"w") as f:
    for link in links:
        if isinstance(link,str) and link.startswith(("vless://","vmess://","trojan://","ss://","hysteria2://")):
            f.write(link+"\n")
print("有效分享链接数量：",len(links))
PY

chmod 600 "$LINKS"

# ------------------------------------------------------------
# 独立订阅服务器：返回 base64 编码的真实分享链接
# ------------------------------------------------------------

cat > "$SUBSCRIPT" <<'PY'
#!/usr/bin/env python3
import base64, os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

TOKEN=os.environ["SUB_TOKEN"]
LINKS=os.environ["LINKS_FILE"]
PORT=int(os.environ["SUB_PORT"])

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        path=urlparse(self.path).path.strip("/")
        if path != TOKEN:
            self.send_error(404)
            return
        try:
            with open(LINKS,"rb") as f:
                data=f.read()
        except Exception:
            self.send_error(503)
            return
        if not data.strip():
            self.send_error(503,"No generated node links")
            return
        body=base64.b64encode(data)
        self.send_response(200)
        self.send_header("Content-Type","text/plain; charset=utf-8")
        self.send_header("Content-Length",str(len(body)))
        self.send_header("Cache-Control","no-store")
        self.end_headers()
        self.wfile.write(body)
    def log_message(self,*args):
        pass

ThreadingHTTPServer(("0.0.0.0",PORT),Handler).serve_forever()
PY

chmod 700 "$SUBSCRIPT"

cat > "$SERVICE" <<EOF
[Unit]
Description=${APP} Subscription Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment="SUB_TOKEN=${SUB_TOKEN}"
Environment="LINKS_FILE=${LINKS}"
Environment="SUB_PORT=${SUB_PORT}"
ExecStart=/usr/bin/python3 ${SUBSCRIPT}
Restart=on-failure
RestartSec=3
User=root
UMask=0077
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ReadOnlyPaths=${LINKS}
ProtectHome=true

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now "${APP}-subscription"

# ------------------------------------------------------------
# 最终验证与结果
# ------------------------------------------------------------

sleep 2
systemctl is-active --quiet "${APP}-subscription" ||
  die "订阅服务没有启动。"

HTTP_CODE="$(curl -sS --max-time 10 \
  -o "${DATA}/subscription-test.txt" \
  -w '%{http_code}' \
  "http://127.0.0.1:${SUB_PORT}/${SUB_TOKEN}" || true)"

[[ "$HTTP_CODE" == "200" ]] ||
  die "订阅 HTTP 验证失败，状态码：${HTTP_CODE}"

chmod 600 "${DATA}/subscription-test.txt"

# 密码和令牌单独存储。
cat > "${ROOT}/credentials.txt" <<EOF
Panel URL: http://${DOMAIN}:${PANEL_PORT}${WEB_PATH}
Panel username: ${USERNAME}
Panel password: ${PASSWORD}
Subscription URL: http://${DOMAIN}:${SUB_PORT}/${SUB_TOKEN}
Subscription port: ${SUB_PORT}
Node links file: ${LINKS}
Log file: ${LOG}
EOF
chmod 600 "${ROOT}/credentials.txt"

printf '\n'
printf '%s\n' '============================================================'
printf '%s\n' '               部署结果'
printf '%s\n' '============================================================'
printf '面板地址： http://%s:%s%s\n' "$DOMAIN" "$PANEL_PORT" "$WEB_PATH"
printf '订阅地址： http://%s:%s/%s\n' "$DOMAIN" "$SUB_PORT" "$SUB_TOKEN"
printf '节点链接： %s\n' "$LINKS"
printf '凭据文件： %s/credentials.txt\n' "$ROOT"
printf '日志文件： %s\n' "$LOG"
printf '成功创建的入站请求数：%s\n' "$CREATED"
printf '订阅 HTTP 状态：%s\n' "$HTTP_CODE"
printf '\n'
warn "订阅当前使用 HTTP，不包含 TLS 加密。不要在不可信网络中公开传输订阅令牌。"
warn "请在云厂商安全组中开放实际使用的 TCP/UDP 端口。"
warn "本脚本不会修改云安全组，也不会自动占用已有的 80/443 端口。"
