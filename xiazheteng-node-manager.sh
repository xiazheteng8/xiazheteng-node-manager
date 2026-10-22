
#!/usr/bin/env bash
# ============================================================
# 瞎折腾吧 | VPS 节点自动部署管理器
# 3x-ui + VLESS REALITY + 随机订阅端口 + 真实订阅验证
# Debian / Ubuntu | root
# ============================================================

set -Eeuo pipefail
umask 077

readonly SCRIPT_VERSION="2.0.0"
readonly INSTALL_URL="https://raw.githubusercontent.com/MHSanaei/3x-ui/master/install.sh"
readonly WORK_DIR="/opt/xiazheteng-node-manager"
readonly SUB_DIR="/opt/xiazheteng-subscription"
readonly SUB_SERVICE="xiazheteng-subscription"
readonly LOG_FILE="/var/log/xiazheteng-node-manager.log"
readonly RESULT_FILE="/root/xiazheteng-node-result.txt"

mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"
chmod 600 "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

log()  { printf '\n[信息] %s\n' "$*"; }
ok()   { printf '[成功] %s\n' "$*"; }
warn() { printf '[警告] %s\n' "$*" >&2; }
die()  { printf '[错误] %s\n' "$*" >&2; exit 1; }

trap 'rc=$?; echo; warn "脚本在第 ${LINENO} 行失败，退出码 ${rc}。日志：${LOG_FILE}"; exit "$rc"' ERR

[[ $EUID -eq 0 ]] || die "请使用 root 运行。"
[[ -r /etc/os-release ]] || die "无法识别操作系统。"
. /etc/os-release

case "${ID:-}" in
  debian|ubuntu) ;;
  *) die "当前版本支持 Debian / Ubuntu。" ;;
esac

command -v apt-get >/dev/null 2>&1 || die "找不到 apt-get。"

echo "============================================================"
echo " 瞎折腾吧 | VPS 节点自动部署管理器 v${SCRIPT_VERSION}"
echo "============================================================"
echo "功能：自动安装 3x-ui、创建 REALITY 节点、生成订阅链接"
echo "策略：必要组件自动安装，其他服务优先避让"
echo

read -r -p "请输入 VPS 公网 IPv4 或已解析的域名: " SERVER_ADDR
SERVER_ADDR="${SERVER_ADDR//[[:space:]]/}"

[[ -n "$SERVER_ADDR" ]] || die "地址不能为空。"
[[ "$SERVER_ADDR" != *"://"* && "$SERVER_ADDR" != */* ]] ||
  die "请输入纯 IP 或域名，不要包含协议和路径。"

if [[ "$SERVER_ADDR" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
  SERVER_KIND="ip"
  python3 - "$SERVER_ADDR" <<'PY'
import ipaddress, sys
ipaddress.IPv4Address(sys.argv[1])
PY
elif [[ "$SERVER_ADDR" =~ ^[A-Za-z0-9.-]+$ && "$SERVER_ADDR" == *.* ]]; then
  SERVER_KIND="domain"
else
  die "地址格式不正确。"
fi

export DEBIAN_FRONTEND=noninteractive

log "安装必要依赖"
apt-get update
apt-get install -y curl ca-certificates jq openssl python3 iproute2

mkdir -p "$WORK_DIR" "$SUB_DIR"
chmod 700 "$WORK_DIR" "$SUB_DIR"

# ------------------------------------------------------------
# 端口检测与自动分配
# ------------------------------------------------------------

port_free() {
  local p="$1"
  ! ss -H -lnt "( sport = :$p )" 2>/dev/null | grep -q .
}

choose_port() {
  local preferred="${1:-0}" p i
  if [[ "$preferred" =~ ^[0-9]+$ ]] &&
     (( preferred >= 1 && preferred <= 65535 )) &&
     port_free "$preferred"; then
    echo "$preferred"
    return 0
  fi

  # 随机选择高位端口，避免占用常见服务端口。
  for ((i=0; i<300; i++)); do
    p="$(shuf -i 20000-60000 -n 1)"
    if port_free "$p"; then
      echo "$p"
      return 0
    fi
  done

  return 1
}

log "检测本机服务及端口"

# 节点端口优先使用常见端口；被占用时自动换高位端口。
NODE_PORT=""
for candidate in 443 2053 8443 24443 32443 42443 52443; do
  if port_free "$candidate"; then
    NODE_PORT="$candidate"
    break
  fi
done
[[ -n "$NODE_PORT" ]] || NODE_PORT="$(choose_port)" ||
  die "无法找到空闲节点端口。"

# 订阅服务始终选择独立端口。
SUB_PORT="$(choose_port)" || die "无法找到空闲订阅端口。"

# ------------------------------------------------------------
# 3x-ui 安装 / 复用
# ------------------------------------------------------------

if systemctl list-unit-files x-ui.service --no-legend 2>/dev/null |
   grep -q 'x-ui.service'; then
  log "检测到现有 x-ui 服务，保留其数据库和已有节点。"
else
  log "下载官方安装器"
  curl -fsSL "$INSTALL_URL" -o "${WORK_DIR}/install-3x-ui.sh"
  [[ -s "${WORK_DIR}/install-3x-ui.sh" ]] ||
    die "官方安装器下载失败。"

  log "执行 3x-ui 官方无人值守安装器"
  XUI_NONINTERACTIVE=1 bash "${WORK_DIR}/install-3x-ui.sh"
fi

systemctl enable --now x-ui
sleep 3
systemctl is-active --quiet x-ui ||
  die "x-ui 服务未正常启动。"

[[ -r /etc/x-ui/install-result.env ]] ||
  die "缺少 /etc/x-ui/install-result.env。请检查官方安装结果，避免覆盖现有面板。"

# 解析官方安装结果，不执行 source，避免执行未知内容。
get_setting() {
  local wanted="$1"
  awk -F= -v wanted="$wanted" '
    {
      key=$1
      gsub(/^[ \t]+|[ \t]+$/, "", key)
      if (tolower(key)==tolower(wanted)) {
        sub(/^[^=]*=/, "")
        gsub(/^[ \t]*["'\'']|["'\''][ \t]*$/, "")
        print
        exit
      }
    }' /etc/x-ui/install-result.env
}

PANEL_USER=""
PANEL_PASS=""
PANEL_PORT=""
PANEL_PATH=""

for key in XUI_USERNAME username USERNAME; do
  PANEL_USER="$(get_setting "$key" || true)"
  [[ -n "$PANEL_USER" ]] && break
done

for key in XUI_PASSWORD password PASSWORD; do
  PANEL_PASS="$(get_setting "$key" || true)"
  [[ -n "$PANEL_PASS" ]] && break
done

for key in XUI_PORT port PORT; do
  PANEL_PORT="$(get_setting "$key" || true)"
  [[ "$PANEL_PORT" =~ ^[0-9]+$ ]] && break
done

for key in XUI_WEB_BASE_PATH webBasePath WEB_BASE_PATH; do
  PANEL_PATH="$(get_setting "$key" || true)"
  [[ -n "$PANEL_PATH" ]] && break
done

[[ -n "$PANEL_USER" && -n "$PANEL_PASS" ]] ||
  die "无法识别面板登录凭据。不会重置现有面板密码或数据库。"

[[ "$PANEL_PORT" =~ ^[0-9]+$ ]] ||
  die "无法识别面板端口。请检查 x-ui 设置及安装结果文件。"

PANEL_PATH="${PANEL_PATH#/}"
PANEL_PATH="${PANEL_PATH%/}"
if [[ -n "$PANEL_PATH" ]]; then
  PANEL_PATH="/${PANEL_PATH}"
fi

BASE_URL="http://127.0.0.1:${PANEL_PORT}${PANEL_PATH}"

# ------------------------------------------------------------
# Xray / REALITY 密钥
# ------------------------------------------------------------

XRAY_BIN="$(command -v xray || true)"
if [[ -z "$XRAY_BIN" ]]; then
  for p in /usr/local/x-ui/bin/xray /usr/local/bin/xray /usr/bin/xray; do
    if [[ -x "$p" ]]; then XRAY_BIN="$p"; break; fi
  done
fi
[[ -n "$XRAY_BIN" ]] || die "找不到 Xray 可执行文件。"

UUID="$(cat /proc/sys/kernel/random/uuid)"
SHORT_ID="$(openssl rand -hex 8)"
CLIENT_EMAIL="auto-$(date +%s)"

KEY_OUTPUT="$("$XRAY_BIN" x25519 2>&1)" ||
  die "当前 Xray 无法生成 REALITY 密钥。"

PRIVATE_KEY="$(printf '%s\n' "$KEY_OUTPUT" |
  sed -nE 's/^[[:space:]]*PrivateKey:[[:space:]]*([^[:space:]]+).*/\1/p' |
  head -n1)"
PUBLIC_KEY="$(printf '%s\n' "$KEY_OUTPUT" |
  sed -nE 's/^[[:space:]]*PublicKey:[[:space:]]*([^[:space:]]+).*/\1/p' |
  head -n1)"

[[ -n "$PRIVATE_KEY" && -n "$PUBLIC_KEY" ]] ||
  die "无法识别当前 Xray 的 x25519 输出格式。"

DEST="www.microsoft.com:443"
SNI="www.microsoft.com"

# ------------------------------------------------------------
# 登录面板 API
# ------------------------------------------------------------

COOKIE_JAR="$(mktemp)"
chmod 600 "$COOKIE_JAR"
trap 'rm -f "${COOKIE_JAR:-}"; rc=$?; if ((rc!=0)); then warn "部署失败，日志：${LOG_FILE}"; fi' EXIT

LOGIN_JSON="$(jq -n \
  --arg username "$PANEL_USER" \
  --arg password "$PANEL_PASS" \
  '{username:$username,password:$password}')"

LOGIN_RESULT="$(curl -fsS --connect-timeout 5 --max-time 15 \
  -c "$COOKIE_JAR" \
  -H 'Content-Type: application/json' \
  -X POST "${BASE_URL}/login" \
  --data "$LOGIN_JSON")" ||
  die "面板 API 登录失败。"

jq -e '.success == true' >/dev/null 2>&1 <<<"$LOGIN_RESULT" ||
  die "面板 API 没有确认登录成功。"

# ------------------------------------------------------------
# 创建节点
# ------------------------------------------------------------

log "创建 VLESS + REALITY 入站，端口 ${NODE_PORT}"

INBOUND_JSON="$(jq -n \
  --argjson port "$NODE_PORT" \
  --arg uuid "$UUID" \
  --arg email "$CLIENT_EMAIL" \
  --arg privateKey "$PRIVATE_KEY" \
  --arg shortId "$SHORT_ID" \
  --arg dest "$DEST" \
  --arg sni "$SNI" \
  '{
    enable: true,
    remark: "XiaZheTeng-Auto-REALITY",
    listen: "",
    port: $port,
    protocol: "vless",
    expiryTime: 0,
    total: 0,
    settings: {
      clients: [{
        id: $uuid,
        email: $email,
        flow: "xtls-rprx-vision",
        enable: true
      }],
      decryption: "none",
      fallbacks: []
    },
    streamSettings: {
      network: "tcp",
      security: "reality",
      realitySettings: {
        show: false,
        dest: $dest,
        xver: 0,
        serverNames: [$sni],
        privateKey: $privateKey,
        minClientVer: "",
        maxClientVer: "",
        maxTimeDiff: 0,
        shortIds: [$shortId]
      }
    },
    sniffing: {
      enabled: true,
      destOverride: ["http", "tls", "quic"],
      metadataOnly: false,
      routeOnly: false
    }
  }')"

ADD_RESULT="$(curl -fsS --connect-timeout 5 --max-time 30 \
  -b "$COOKIE_JAR" \
  -H 'Content-Type: application/json' \
  -X POST "${BASE_URL}/panel/api/inbounds/add" \
  --data "$INBOUND_JSON")" ||
  die "创建入站的 API 请求失败。"

jq -e '.success == true' >/dev/null 2>&1 <<<"$ADD_RESULT" || {
  printf '%s\n' "$ADD_RESULT" >&2
  die "面板没有确认入站创建成功。"
}

LIST_RESULT="$(curl -fsS --connect-timeout 5 --max-time 20 \
  -b "$COOKIE_JAR" \
  "${BASE_URL}/panel/api/inbounds/list")" ||
  die "无法读取入站列表。"

jq -e --argjson port "$NODE_PORT" \
  '(.obj // []) | any(.port == $port and .protocol == "vless")' \
  >/dev/null 2>&1 <<<"$LIST_RESULT" ||
  die "未在入站列表中找到新创建的节点。"

# ------------------------------------------------------------
# 生成节点 URI
# ------------------------------------------------------------

VLESS_LINK="vless://${UUID}@${SERVER_ADDR}:${NODE_PORT}?encryption=none&security=reality&type=tcp&flow=xtls-rprx-vision&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&spx=%2F#XiaZheTeng-REALITY"

printf '%s\n' "$VLESS_LINK" | base64 -w0 > "${SUB_DIR}/subscription.b64"
printf '\n' >> "${SUB_DIR}/subscription.b64"
printf '%s\n' "$VLESS_LINK" > "${SUB_DIR}/node-link.txt"

SUB_TOKEN="$(openssl rand -hex 24)"
printf '%s\n' "$SUB_TOKEN" > "${SUB_DIR}/token"
chmod 600 "${SUB_DIR}/subscription.b64" "${SUB_DIR}/node-link.txt" "${SUB_DIR}/token"

# ------------------------------------------------------------
# 建立独立订阅服务
# 端口冲突时使用随机备用端口，不占用 Nginx 的 80/443。
# ------------------------------------------------------------

log "配置订阅服务，端口 ${SUB_PORT}"

cat > "${SUB_DIR}/server.py" <<'PY'
#!/usr/bin/env python3
import http.server
import pathlib
import os

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
chmod 700 "${SUB_DIR}/server.py"

# 只替换本脚本自己管理的服务单元。
cat > "/etc/systemd/system/${SUB_SERVICE}.service" <<UNIT
[Unit]
Description=XiaZheTeng subscription endpoint
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
UMask=0077
Environment=SUB_PORT=${SUB_PORT}
ExecStart=/usr/bin/python3 ${SUB_DIR}/server.py
Restart=on-failure
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ReadOnlyPaths=${SUB_DIR}

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now "${SUB_SERVICE}"
sleep 1
systemctl is-active --quiet "${SUB_SERVICE}" ||
  die "订阅服务启动失败。"

# ------------------------------------------------------------
# 本机验证真实订阅内容
# ------------------------------------------------------------

SUB_LOCAL="http://127.0.0.1:${SUB_PORT}/sub/${SUB_TOKEN}"
SUB_RESPONSE="$(curl -fsS --connect-timeout 3 --max-time 10 "$SUB_LOCAL")" ||
  die "订阅接口本机验证失败。"

DECODED_SUB="$(printf '%s' "$SUB_RESPONSE" | base64 -d 2>/dev/null)" ||
  die "订阅返回内容不是有效 Base64。"

grep -Fq "$UUID" <<<"$DECODED_SUB" ||
  die "订阅内容中没有刚创建节点的 UUID。"

grep -Fq "vless://" <<<"$DECODED_SUB" ||
  die "订阅内容中没有 VLESS 分享链接。"

# ------------------------------------------------------------
# 防火墙：只增加需要的端口，不清空已有规则
# ------------------------------------------------------------

if command -v ufw >/dev/null 2>&1 &&
   ufw status 2>/dev/null | grep -q '^Status: active'; then
  ufw allow "${NODE_PORT}/tcp" >/dev/null ||
    warn "无法自动添加节点端口规则，请检查 UFW。"
  ufw allow "${SUB_PORT}/tcp" >/dev/null ||
    warn "无法自动添加订阅端口规则，请检查 UFW。"
fi

if command -v firewall-cmd >/dev/null 2>&1 &&
   firewall-cmd --state >/dev/null 2>&1; then
  firewall-cmd --permanent --add-port="${NODE_PORT}/tcp" ||
    warn "无法自动添加 firewalld 节点规则。"
  firewall-cmd --permanent --add-port="${SUB_PORT}/tcp" ||
    warn "无法自动添加 firewalld 订阅规则。"
  firewall-cmd --reload ||
    warn "firewalld reload 失败，请检查现有规则。"
fi

# ------------------------------------------------------------
# 输出结果
# ------------------------------------------------------------

SUB_URL="http://${SERVER_ADDR}:${SUB_PORT}/sub/${SUB_TOKEN}"

cat > "$RESULT_FILE" <<EOF
瞎折腾吧 | VPS 节点部署结果
============================

节点协议：VLESS + REALITY + TCP
节点地址：${SERVER_ADDR}
节点端口：${NODE_PORT}

节点分享链接：
${VLESS_LINK}

订阅链接：
${SUB_URL}

面板端口：
${PANEL_PORT}

面板用户名：
${PANEL_USER}

面板密码：
${PANEL_PASS}

订阅服务端口：
${SUB_PORT}

注意：
1. 本机订阅内容验证成功，不代表公网可达。
2. 请检查云厂商安全组是否放行 TCP ${NODE_PORT} 和 TCP ${SUB_PORT}。
3. 此订阅接口默认使用 HTTP；订阅 URL 含访问令牌，不要公开传播。
4. 域名输入不会自动申请 TLS 证书，也不会覆盖已有 Nginx 配置。
5. 订阅服务端口与节点端口均由本脚本动态选择。
EOF
chmod 600 "$RESULT_FILE"

echo
echo "============================================================"
ok "节点已创建，订阅内容本机验证通过。"
echo "============================================================"
echo
echo "节点分享链接："
echo "$VLESS_LINK"
echo
echo "订阅链接："
echo "$SUB_URL"
echo
echo "3x-ui 面板端口：$PANEL_PORT"
echo "3x-ui 用户名：$PANEL_USER"
echo "3x-ui 密码：$PANEL_PASS"
echo
echo "结果文件：$RESULT_FILE"
echo "日志文件：$LOG_FILE"
echo
warn "请在云安全组中放行 TCP ${NODE_PORT} 和 TCP ${SUB_PORT}。"
warn "公网可达性尚未从外部网络验证。"
