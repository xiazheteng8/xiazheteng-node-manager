
#!/usr/bin/env bash
# ============================================================
# 瞎折腾吧 | 3x-ui 自动部署器
# 自动安装/复用 3x-ui、创建 VLESS REALITY、生成真实订阅
# Debian / Ubuntu | root
# ============================================================

set -Eeuo pipefail
umask 077

readonly INSTALL_URL="https://raw.githubusercontent.com/MHSanaei/3x-ui/master/install.sh"
readonly DB="/etc/x-ui/x-ui.db"
readonly RESULT="/etc/x-ui/install-result.env"
readonly SUBDIR="/opt/xiazheteng-subscription"
readonly SUBSERVICE="xiazheteng-subscription"
readonly LOG="/var/log/xiazheteng-node-manager.log"
readonly OUT="/root/xiazheteng-node-result.txt"

mkdir -p /var/log
touch "$LOG"
chmod 600 "$LOG"
exec > >(tee -a "$LOG") 2>&1

log()  { echo -e "\n[信息] $*"; }
ok()   { echo "[成功] $*"; }
warn() { echo "[警告] $*" >&2; }
die()  { echo "[错误] $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "请使用 root 运行。"
[[ -r /etc/os-release ]] || die "无法识别操作系统。"
. /etc/os-release
[[ "${ID:-}" == "debian" || "${ID:-}" == "ubuntu" ]] ||
  die "仅支持 Debian / Ubuntu。"

read -r -p "请输入 VPS 公网 IPv4 或域名: " SERVER
SERVER="${SERVER//[[:space:]]/}"
[[ -n "$SERVER" && "$SERVER" != *"://"* && "$SERVER" != */* ]] ||
  die "请输入纯 IP 或域名。"

if [[ "$SERVER" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
  SERVER_KIND="ip"
  python3 - "$SERVER" <<'PY'
import ipaddress,sys
ipaddress.IPv4Address(sys.argv[1])
PY
elif [[ "$SERVER" =~ ^[A-Za-z0-9.-]+$ && "$SERVER" == *.* ]]; then
  SERVER_KIND="domain"
else
  die "地址格式不正确。"
fi

export DEBIAN_FRONTEND=noninteractive

log "安装基础工具"
apt-get update
apt-get install -y curl ca-certificates jq openssl python3 iproute2 sqlite3

mkdir -p "$SUBDIR"
chmod 700 "$SUBDIR"

# ------------------------------------------------------------
# 端口管理
# ------------------------------------------------------------

port_free() {
  ! ss -H -lnt "( sport = :$1 )" 2>/dev/null | grep -q .
}

choose_port() {
  local p i
  for ((i=0; i<500; i++)); do
    p="$(shuf -i 20000-60000 -n 1)"
    [[ "${p}" == "${NODE_PORT:-}" ]] && continue
    if port_free "$p"; then
      echo "$p"
      return 0
    fi
  done
  return 1
}

NODE_PORT=""
for p in 443 2053 8443 24443 32443 42443 52443; do
  if port_free "$p"; then
    NODE_PORT="$p"
    break
  fi
done
[[ -n "$NODE_PORT" ]] || NODE_PORT="$(choose_port)" ||
  die "无法找到可用节点端口。"

SUB_PORT="$(choose_port)" || die "无法找到可用订阅端口。"

log "节点端口：${NODE_PORT}"
log "订阅端口：${SUB_PORT}"

# ------------------------------------------------------------
# 安装或复用 3x-ui
# 不删除数据库，不清空原有入站。
# ------------------------------------------------------------

if systemctl cat x-ui.service >/dev/null 2>&1; then
  log "发现已有 x-ui 服务，保留数据库和已有节点"
  systemctl enable x-ui
  systemctl restart x-ui
elif [[ -f "$DB" ]]; then
  log "发现旧数据库但缺少 x-ui 服务，先备份数据库"
  cp -a "$DB" "${DB}.backup.$(date +%Y%m%d%H%M%S)"
  curl -fsSL "$INSTALL_URL" -o /tmp/xui-installer.sh
  XUI_NONINTERACTIVE=1 bash /tmp/xui-installer.sh
  rm -f /tmp/xui-installer.sh
  systemctl enable --now x-ui
else
  log "未发现已有安装，执行官方无人值守安装"
  curl -fsSL "$INSTALL_URL" -o /tmp/xui-installer.sh
  [[ -s /tmp/xui-installer.sh ]] || die "安装器下载失败。"
  XUI_NONINTERACTIVE=1 bash /tmp/xui-installer.sh
  rm -f /tmp/xui-installer.sh
  systemctl enable --now x-ui
fi

sleep 3
systemctl is-active --quiet x-ui || {
  journalctl -u x-ui -n 80 --no-pager >&2 || true
  die "x-ui 启动失败。"
}

# ------------------------------------------------------------
# 安全读取安装结果；没有结果文件时读取 SQLite 设置。
# 不执行 source，不执行数据库中的内容。
# ------------------------------------------------------------

env_value() {
  local key="$1"
  [[ -r "$RESULT" ]] || return 0
  sed -nE \
    "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*['\"]?([^'\"]*)['\"]?[[:space:]]*$/\1/p" \
    "$RESULT" | head -n1
}

db_value() {
  local key="$1"
  [[ -f "$DB" ]] || return 0
  sqlite3 -readonly "$DB" \
    "SELECT value FROM settings WHERE key='${key}' LIMIT 1;" 2>/dev/null || true
}

PANEL_USER=""
PANEL_PASS=""
PANEL_PORT=""
PANEL_PATH=""

for k in XUI_USERNAME USERNAME username; do
  PANEL_USER="$(env_value "$k")"
  [[ -n "$PANEL_USER" ]] && break
done

for k in XUI_PASSWORD PASSWORD password; do
  PANEL_PASS="$(env_value "$k")"
  [[ -n "$PANEL_PASS" ]] && break
done

for k in XUI_PORT PORT port; do
  PANEL_PORT="$(env_value "$k")"
  [[ "$PANEL_PORT" =~ ^[0-9]+$ ]] && break
done

for k in XUI_WEB_BASE_PATH WEB_BASE_PATH webBasePath; do
  PANEL_PATH="$(env_value "$k")"
  [[ -n "$PANEL_PATH" ]] && break
done

# 已有安装通常从数据库读取。
[[ -n "$PANEL_USER" ]] || PANEL_USER="$(db_value username)"
[[ -n "$PANEL_PASS" ]] || PANEL_PASS="$(db_value password)"
[[ "$PANEL_PORT" =~ ^[0-9]+$ ]] || PANEL_PORT="$(db_value webPort)"
[[ -n "$PANEL_PATH" ]] || PANEL_PATH="$(db_value webBasePath)"

[[ -n "$PANEL_USER" && -n "$PANEL_PASS" ]] ||
  die "无法获取面板凭据。请检查官方安装结果文件或 SQLite 数据库。"

[[ "$PANEL_PORT" =~ ^[0-9]+$ ]] ||
  die "无法获取面板端口，请检查 3x-ui 设置。"

# 面板端口若没有监听，不能仅凭数据库信息继续。
ss -H -lnt "( sport = :$PANEL_PORT )" | grep -q . ||
  die "面板端口 ${PANEL_PORT} 没有监听，请检查 x-ui 配置。"

PANEL_PATH="${PANEL_PATH#/}"
PANEL_PATH="${PANEL_PATH%/}"
[[ -z "$PANEL_PATH" ]] || PANEL_PATH="/${PANEL_PATH}"
BASE_URL="http://127.0.0.1:${PANEL_PORT}${PANEL_PATH}"

# ------------------------------------------------------------
# 定位 Xray 并生成 REALITY 密钥
# ------------------------------------------------------------

XRAY="$(command -v xray || true)"
if [[ -z "$XRAY" ]]; then
  for p in /usr/local/x-ui/bin/xray /usr/local/bin/xray /usr/bin/xray; do
    [[ -x "$p" ]] && XRAY="$p" && break
  done
fi
[[ -n "$XRAY" ]] || die "未找到 Xray 可执行文件。"

UUID="$(cat /proc/sys/kernel/random/uuid)"
SHORT_ID="$(openssl rand -hex 8)"
EMAIL="auto-$(date +%s)"
SNI="www.microsoft.com"
DEST="${SNI}:443"

KEYS="$("$XRAY" x25519 2>&1)" || die "Xray x25519 执行失败。"
PRIVATE_KEY="$(sed -nE 's/^[[:space:]]*PrivateKey:[[:space:]]*([^[:space:]]+).*/\1/p' <<<"$KEYS" | head -n1)"
PUBLIC_KEY="$(sed -nE 's/^[[:space:]]*PublicKey:[[:space:]]*([^[:space:]]+).*/\1/p' <<<"$KEYS" | head -n1)"
[[ -n "$PRIVATE_KEY" && -n "$PUBLIC_KEY" ]] ||
  die "无法解析 Xray 密钥输出。"

# ------------------------------------------------------------
# 面板 API 登录
# ------------------------------------------------------------

COOKIE="$(mktemp)"
chmod 600 "$COOKIE"
trap 'rm -f "${COOKIE:-}"' EXIT

LOGIN="$(jq -n --arg username "$PANEL_USER" --arg password "$PANEL_PASS" \
  '{username:$username,password:$password}')"

LOGIN_RESULT="$(curl -fsS --connect-timeout 5 --max-time 15 \
  -c "$COOKIE" -H 'Content-Type: application/json' \
  -X POST "${BASE_URL}/login" -d "$LOGIN")" ||
  die "面板 API 登录失败，请检查端口、访问路径和凭据。"

jq -e '.success == true' >/dev/null 2>&1 <<<"$LOGIN_RESULT" ||
  die "面板 API 登录未成功。"

# ------------------------------------------------------------
# 创建入站。不会删除原有节点。
# ------------------------------------------------------------

INBOUND="$(jq -n \
  --argjson port "$NODE_PORT" \
  --arg uuid "$UUID" \
  --arg email "$EMAIL" \
  --arg privateKey "$PRIVATE_KEY" \
  --arg shortId "$SHORT_ID" \
  --arg sni "$SNI" \
  --arg dest "$DEST" \
  '{
    enable:true,
    remark:"XiaZheTeng-Auto-REALITY",
    listen:"",
    port:$port,
    protocol:"vless",
    expiryTime:0,
    total:0,
    settings:{
      clients:[{
        id:$uuid,
        email:$email,
        flow:"xtls-rprx-vision",
        enable:true
      }],
      decryption:"none",
      fallbacks:[]
    },
    streamSettings:{
      network:"tcp",
      security:"reality",
      realitySettings:{
        show:false,
        dest:$dest,
        xver:0,
        serverNames:[$sni],
        privateKey:$privateKey,
        minClientVer:"",
        maxClientVer:"",
        maxTimeDiff:0,
        shortIds:[$shortId]
      }
    },
    sniffing:{
      enabled:true,
      destOverride:["http","tls","quic"],
      metadataOnly:false,
      routeOnly:false
    }
  }')"

ADD="$(curl -fsS --connect-timeout 5 --max-time 30 \
  -b "$COOKIE" -H 'Content-Type: application/json' \
  -X POST "${BASE_URL}/panel/api/inbounds/add" -d "$INBOUND")" ||
  die "创建入站 API 请求失败。"

jq -e '.success == true' >/dev/null 2>&1 <<<"$ADD" || {
  echo "$ADD" >&2
  die "面板未确认节点创建成功。"
}

LIST="$(curl -fsS --connect-timeout 5 --max-time 20 \
  -b "$COOKIE" "${BASE_URL}/panel/api/inbounds/list")" ||
  die "读取入站列表失败。"

jq -e --argjson port "$NODE_PORT" \
  '(.obj // []) | any(.port == $port and .protocol == "vless")' \
  >/dev/null 2>&1 <<<"$LIST" ||
  die "入站列表中未找到新节点。"

# ------------------------------------------------------------
# 生成分享链接和独立订阅服务
# ------------------------------------------------------------

LINK="vless://${UUID}@${SERVER}:${NODE_PORT}?encryption=none&security=reality&type=tcp&flow=xtls-rprx-vision&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&spx=%2F#XiaZheTeng-REALITY"

TOKEN="$(openssl rand -hex 24)"
printf '%s\n' "$LINK" | base64 -w0 > "${SUBDIR}/subscription.b64"
printf '\n' >> "${SUBDIR}/subscription.b64"
printf '%s\n' "$LINK" > "${SUBDIR}/node-link.txt"
printf '%s\n' "$TOKEN" > "${SUBDIR}/token"
chmod 600 "${SUBDIR}/subscription.b64" "${SUBDIR}/node-link.txt" "${SUBDIR}/token"

cat > "${SUBDIR}/server.py" <<'PY'
#!/usr/bin/env python3
import http.server, pathlib, os

root = pathlib.Path("/opt/xiazheteng-subscription")
token = (root / "token").read_text().strip()
payload = (root / "subscription.b64").read_bytes().strip() + b"\n"
port = int(os.environ["SUB_PORT"])

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/sub/" + token:
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)
    def log_message(self, fmt, *args):
        pass

http.server.ThreadingHTTPServer(("0.0.0.0", port), Handler).serve_forever()
PY
chmod 700 "${SUBDIR}/server.py"

cat > "/etc/systemd/system/${SUBSERVICE}.service" <<UNIT
[Unit]
Description=XiaZheTeng subscription endpoint
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
UMask=0077
Environment=SUB_PORT=${SUB_PORT}
ExecStart=/usr/bin/python3 ${SUBDIR}/server.py
Restart=on-failure
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ReadOnlyPaths=${SUBDIR}

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now "$SUBSERVICE"
sleep 1
systemctl is-active --quiet "$SUBSERVICE" ||
  die "订阅服务启动失败。"

SUB_LOCAL="http://127.0.0.1:${SUB_PORT}/sub/${TOKEN}"
RESPONSE="$(curl -fsS --connect-timeout 3 --max-time 10 "$SUB_LOCAL")" ||
  die "本机订阅请求失败。"

DECODED="$(printf '%s' "$RESPONSE" | base64 -d 2>/dev/null)" ||
  die "订阅返回内容不是有效 Base64。"

grep -Fq "$UUID" <<<"$DECODED" ||
  die "订阅内容不包含本次节点 UUID。"

SUB_URL="http://${SERVER}:${SUB_PORT}/sub/${TOKEN}"

# 仅添加防火墙规则，不清空已有规则。
if command -v ufw >/dev/null 2>&1 &&
   ufw status 2>/dev/null | grep -q '^Status: active'; then
  ufw allow "${NODE_PORT}/tcp" >/dev/null || warn "无法添加 UFW 节点端口规则。"
  ufw allow "${SUB_PORT}/tcp" >/dev/null || warn "无法添加 UFW 订阅端口规则。"
fi

cat > "$OUT" <<EOF
瞎折腾吧 | 节点部署结果

节点分享链接：
${LINK}

订阅链接：
${SUB_URL}

面板地址：
http://${SERVER}:${PANEL_PORT}${PANEL_PATH}

面板用户名：
${PANEL_USER}

面板密码：
${PANEL_PASS}

节点端口：${NODE_PORT}
订阅端口：${SUB_PORT}
日志文件：${LOG}
EOF
chmod 600 "$OUT"

echo
echo "============================================================"
ok "节点创建成功，订阅内容已通过本机验证。"
echo "============================================================"
echo
echo "节点分享链接："
echo "$LINK"
echo
echo "订阅链接："
echo "$SUB_URL"
echo
echo "面板地址：http://${SERVER}:${PANEL_PORT}${PANEL_PATH}"
echo "面板用户名：${PANEL_USER}"
echo "面板密码：${PANEL_PASS}"
echo
echo "结果文件：$OUT"
echo "日志文件：$LOG"
warn "请在云厂商安全组放行 TCP ${NODE_PORT} 和 TCP ${SUB_PORT}。"
warn "当前订阅使用 HTTP；尚未自动申请 HTTPS 证书或配置反向代理。"
warn "公网可达性需要从外部网络验证。"
