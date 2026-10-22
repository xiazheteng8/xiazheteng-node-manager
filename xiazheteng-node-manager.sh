
#!/usr/bin/env bash
# ============================================================
# 瞎折腾吧 | 3x-ui 一键安装 + VLESS REALITY + 订阅服务
# 支持 Debian / Ubuntu，要求 root
# ============================================================

set -Eeuo pipefail
umask 077

readonly INSTALL_URL="https://raw.githubusercontent.com/MHSanaei/3x-ui/master/install.sh"
readonly RESULT_FILE="/etc/x-ui/install-result.env"
readonly SUB_DIR="/opt/xiazheteng-subscription"
readonly SUB_SERVICE="/etc/systemd/system/xiazheteng-subscription.service"
readonly SUB_PORT="2096"

log()  { printf '\n\033[1;36m[信息]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[成功]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[警告]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[错误]\033[0m %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "请使用 root 运行。"
[[ -r /etc/os-release ]] || die "无法识别系统。"
. /etc/os-release

case "${ID:-}" in
  debian|ubuntu) ;;
  *) die "当前脚本只允许在 Debian / Ubuntu 上运行。" ;;
esac

command -v apt-get >/dev/null || die "找不到 apt-get。"

echo "============================================================"
echo " 瞎折腾吧 | 3x-ui 自动部署"
echo " 自动安装面板、创建 REALITY 节点、生成订阅链接"
echo "============================================================"
echo
warn "请在全新 VPS 上运行。脚本不会自动覆盖已有网站或服务。"
echo

read -r -p "请输入 VPS 公网 IP 或已解析到本机的域名: " SERVER_ADDR
SERVER_ADDR="${SERVER_ADDR//[[:space:]]/}"

[[ -n "$SERVER_ADDR" ]] || die "地址不能为空。"
[[ "$SERVER_ADDR" != *"/"* && "$SERVER_ADDR" != *"@"* ]] ||
  die "请输入纯 IP 或域名，不要包含协议、路径或用户名。"

if [[ "$SERVER_ADDR" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  SERVER_KIND="ip"
elif [[ "$SERVER_ADDR" =~ ^[a-zA-Z0-9.-]+$ && "$SERVER_ADDR" == *.* ]]; then
  SERVER_KIND="domain"
else
  die "地址格式不正确。"
fi

log "检查现有服务及端口"

# 不覆盖现有的 3x-ui 安装。
if systemctl is-active --quiet x-ui 2>/dev/null; then
  die "检测到 x-ui 已在运行。为避免覆盖现有配置，脚本停止。"
fi

# 选取一个空闲 TCP 端口。
port_free() {
  local p="$1"
  ! ss -H -lnt "( sport = :$p )" 2>/dev/null | grep -q .
}

NODE_PORT=""
for p in 443 2053 8443 24443 32443 42443 52443; do
  if port_free "$p"; then
    NODE_PORT="$p"
    break
  fi
done
[[ -n "$NODE_PORT" ]] || die "没有找到可用的节点端口，请先释放端口。"

if ! port_free "$SUB_PORT"; then
  die "订阅服务端口 $SUB_PORT 已被占用。请释放该端口后重试。"
fi

log "安装系统依赖"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y curl ca-certificates jq openssl python3 iproute2

# 防止在现有数据库上重复创建或覆盖配置。
if [[ -e /etc/x-ui/x-ui.db || -e "$RESULT_FILE" ]]; then
  die "检测到现有 3x-ui 数据文件或安装结果。请先确认服务器状态，脚本不会覆盖。"
fi

log "通过官方无人值守安装器安装 3x-ui"
curl -fsSL "$INSTALL_URL" -o /tmp/xui-official-install.sh
[[ -s /tmp/xui-official-install.sh ]] || die "官方安装脚本下载失败。"

XUI_NONINTERACTIVE=1 bash /tmp/xui-official-install.sh
rm -f /tmp/xui-official-install.sh

systemctl enable --now x-ui
sleep 3
systemctl is-active --quiet x-ui || die "3x-ui 服务没有成功启动。"

[[ -r "$RESULT_FILE" ]] ||
  die "没有找到官方安装结果文件 $RESULT_FILE，无法安全自动登录面板。"

# 安装结果由官方安装器生成。仅提取所需字段，不执行 source。
read_env_value() {
  local wanted="$1"
  sed -nE \
    "s/^[[:space:]]*${wanted}[[:space:]]*=[[:space:]]*['\"]?([^'\"]*)['\"]?[[:space:]]*$/\1/p" \
    "$RESULT_FILE" | head -n1
}

# 官方安装结果文件的变量名随版本可能变化，兼容常见命名。
PANEL_USER=""
PANEL_PASS=""
PANEL_PORT=""
PANEL_PATH=""

for key in XUI_USERNAME USERNAME username; do
  PANEL_USER="$(read_env_value "$key" || true)"
  [[ -n "$PANEL_USER" ]] && break
done

for key in XUI_PASSWORD PASSWORD password; do
  PANEL_PASS="$(read_env_value "$key" || true)"
  [[ -n "$PANEL_PASS" ]] && break
done

for key in XUI_PORT PORT port; do
  PANEL_PORT="$(read_env_value "$key" || true)"
  [[ "$PANEL_PORT" =~ ^[0-9]+$ ]] && break
done

for key in XUI_WEB_BASE_PATH WEB_BASE_PATH webBasePath; do
  PANEL_PATH="$(read_env_value "$key" || true)"
  [[ -n "$PANEL_PATH" ]] && break
done

[[ -n "$PANEL_USER" && -n "$PANEL_PASS" ]] ||
  die "无法从官方安装结果中识别面板凭据；面板已安装，但自动部署未完成。"

[[ "$PANEL_PORT" =~ ^[0-9]+$ ]] || {
  warn "安装结果未提供可识别的面板端口，尝试从监听端口中识别。"
  PANEL_PORT="$(ss -H -lntp 2>/dev/null |
    sed -nE 's/.*127\.0\.0\.1:([0-9]+).*/\1/p' | head -n1)"
}
[[ "$PANEL_PORT" =~ ^[0-9]+$ ]] ||
  die "无法识别面板端口，请检查 x-ui 设置。"

PANEL_PATH="${PANEL_PATH#/}"
[[ -n "$PANEL_PATH" ]] && PANEL_PATH="/$PANEL_PATH"
PANEL_PATH="${PANEL_PATH%/}"

BASE_URL="http://127.0.0.1:${PANEL_PORT}${PANEL_PATH}"

log "检查 Xray 可执行文件"
XRAY_BIN="$(command -v xray || true)"
if [[ -z "$XRAY_BIN" ]]; then
  for p in /usr/local/x-ui/bin/xray /usr/local/bin/xray /usr/bin/xray; do
    [[ -x "$p" ]] && XRAY_BIN="$p" && break
  done
fi
[[ -n "$XRAY_BIN" ]] || die "未找到 Xray 可执行文件。"

log "生成节点参数"
UUID="$(cat /proc/sys/kernel/random/uuid)"
SHORT_ID="$(openssl rand -hex 8)"
SUB_TOKEN="$(openssl rand -hex 24)"
CLIENT_EMAIL="auto-$(date +%s)"

# REALITY 的公私钥由当前 Xray 生成。
KEY_OUTPUT="$("$XRAY_BIN" x25519 2>&1)" ||
  die "Xray 不支持 x25519 命令，无法生成 REALITY 密钥。"

PRIVATE_KEY="$(printf '%s\n' "$KEY_OUTPUT" |
  sed -nE 's/^[[:space:]]*PrivateKey:[[:space:]]*([^[:space:]]+).*/\1/p' |
  head -n1)"
PUBLIC_KEY="$(printf '%s\n' "$KEY_OUTPUT" |
  sed -nE 's/^[[:space:]]*PublicKey:[[:space:]]*([^[:space:]]+).*/\1/p' |
  head -n1)"

[[ -n "$PRIVATE_KEY" && -n "$PUBLIC_KEY" ]] ||
  die "无法识别 Xray x25519 输出格式；未创建节点。"

DEST="www.microsoft.com:443"
SNI="www.microsoft.com"

log "登录 3x-ui API"
COOKIE_JAR="$(mktemp)"
chmod 600 "$COOKIE_JAR"
trap 'rm -f "${COOKIE_JAR:-}"' EXIT

LOGIN_JSON="$(jq -n \
  --arg username "$PANEL_USER" \
  --arg password "$PANEL_PASS" \
  '{username:$username,password:$password}')"

LOGIN_RESULT="$(curl -fsS --connect-timeout 5 --max-time 15 \
  -c "$COOKIE_JAR" \
  -H 'Content-Type: application/json' \
  -X POST "${BASE_URL}/login" \
  --data "$LOGIN_JSON")" ||
  die "面板 API 登录失败。请检查面板端口、访问路径及官方安装结果。"

if ! jq -e '.success == true' >/dev/null 2>&1 <<<"$LOGIN_RESULT"; then
  die "面板 API 未确认登录成功，停止创建节点。"
fi

log "创建 VLESS + REALITY 入站"

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
    remark: "Auto-VLESS-REALITY",
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
  die "创建入站 API 请求失败。"

if ! jq -e '.success == true' >/dev/null 2>&1 <<<"$ADD_RESULT"; then
  printf '%s\n' "$ADD_RESULT" >&2
  die "3x-ui 未确认入站创建成功。"
fi

# 再次读取入站列表，确认服务端确实保存了节点。
LIST_RESULT="$(curl -fsS --connect-timeout 5 --max-time 20 \
  -b "$COOKIE_JAR" \
  "${BASE_URL}/panel/api/inbounds/list")" ||
  die "无法读取入站列表，无法验证创建结果。"

if ! jq -e --argjson port "$NODE_PORT" \
  '(.obj // []) | any(.port == $port and .protocol == "vless")' \
  >/dev/null 2>&1 <<<"$LIST_RESULT"; then
  die "入站列表中未找到刚创建的 VLESS 节点。"
fi

log "生成订阅内容"
# 分享链接使用 URL 编码后的参数，避免特殊字符破坏 URI。
VLESS_LINK="vless://${UUID}@${SERVER_ADDR}:${NODE_PORT}?encryption=none&security=reality&type=tcp&flow=xtls-rprx-vision&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&spx=%2F#XiaZheTeng-REALITY"

mkdir -p "$SUB_DIR"
printf '%s\n' "$VLESS_LINK" | base64 -w0 > "${SUB_DIR}/subscription.b64"
printf '\n' >> "${SUB_DIR}/subscription.b64"
printf '%s\n' "$VLESS_LINK" > "${SUB_DIR}/node-link.txt"
printf '%s\n' "$SUB_TOKEN" > "${SUB_DIR}/token"
chmod 700 "$SUB_DIR"
chmod 600 "$SUB_DIR"/*

# 仅监听订阅端口；必须用随机 token 访问订阅内容。
cat > "${SUB_DIR}/server.py" <<'PY'
#!/usr/bin/env python3
import http.server
import pathlib
import sys
import hmac

root = pathlib.Path("/opt/xiazheteng-subscription")
token = (root / "token").read_text().strip()
payload = (root / "subscription.b64").read_bytes().strip() + b"\n"

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

http.server.ThreadingHTTPServer(("0.0.0.0", 2096), Handler).serve_forever()
PY
chmod 700 "${SUB_DIR}/server.py"

cat > "$SUB_SERVICE" <<'UNIT'
[Unit]
Description=XiaZheTeng subscription endpoint
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
UMask=0077
ExecStart=/usr/bin/python3 /opt/xiazheteng-subscription/server.py
Restart=on-failure
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ReadOnlyPaths=/opt/xiazheteng-subscription

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now xiazheteng-subscription
sleep 1
systemctl is-active --quiet xiazheteng-subscription ||
  die "订阅服务启动失败。"

# 先从本机验证真实订阅响应。
SUB_LOCAL="http://127.0.0.1:${SUB_PORT}/sub/${SUB_TOKEN}"
SUB_RESPONSE="$(curl -fsS --connect-timeout 3 --max-time 10 "$SUB_LOCAL")" ||
  die "本机订阅接口验证失败。"

if ! grep -Fq "$UUID" <<<"$(printf '%s' "$SUB_RESPONSE" | base64 -d 2>/dev/null || true)"; then
  die "订阅响应中未发现已创建节点的 UUID。"
fi

# 尝试开放端口；不改写现有防火墙规则。
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
  ufw allow "${NODE_PORT}/tcp" >/dev/null || warn "请手动开放节点 TCP 端口 ${NODE_PORT}。"
  ufw allow "${SUB_PORT}/tcp" >/dev/null || warn "请手动开放订阅 TCP 端口 ${SUB_PORT}。"
fi

# 检测云厂商安全组/公网映射无法由本机脚本确认。
SUB_URL="http://${SERVER_ADDR}:${SUB_PORT}/sub/${SUB_TOKEN}"

# 将敏感部署结果单独保存，避免写入普通日志。
cat > /root/xiazheteng-node-result.txt <<EOF
3x-ui 自动部署结果
==================
面板端口：${PANEL_PORT}
面板用户名：${PANEL_USER}
面板密码：${PANEL_PASS}

节点协议：VLESS + REALITY + TCP
节点地址：${SERVER_ADDR}
节点端口：${NODE_PORT}
节点分享链接：
${VLESS_LINK}

订阅链接：
${SUB_URL}

说明：
1. 订阅接口已在本机验证。
2. 请确认云安全组放行 TCP ${NODE_PORT} 和 TCP ${SUB_PORT}。
3. 当前订阅接口使用 HTTP；不要在不可信网络中公开该订阅 URL。
4. 如果使用域名，需另外配置 HTTPS 反向代理和有效证书。
EOF
chmod 600 /root/xiazheteng-node-result.txt

echo
echo "============================================================"
ok "本机部署步骤完成，节点已通过面板 API 验证。"
echo "============================================================"
echo
printf '节点分享链接：\n%s\n\n' "$VLESS_LINK"
printf '订阅链接：\n%s\n\n' "$SUB_URL"
printf '面板端口：%s\n' "$PANEL_PORT"
printf '面板用户名：%s\n' "$PANEL_USER"
printf '面板密码：%s\n' "$PANEL_PASS"
echo
echo "完整结果已保存：/root/xiazheteng-node-result.txt"
echo
warn "公网可达性取决于云安全组、端口映射和运营商网络；脚本无法仅凭本机检测保证外网客户端连接成功。"
