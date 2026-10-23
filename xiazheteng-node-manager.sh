
#!/usr/bin/env bash
# ============================================================
# 瞎折腾吧 | 3x-ui VPS 节点管理器
# 功能：
#   1. 自动安装或复用 3x-ui
#   2. 检查面板 API 登录
#   3. 自动同步面板中的节点分享链接
#   4. 独立订阅 HTTP 服务
#   5. systemd 定时同步，面板手动新增节点自动进入订阅
#   6. 日志、配置备份、失败保护
#
# 支持 Debian / Ubuntu
# ============================================================

set -Eeuo pipefail
umask 077

APP="xiazheteng-node-manager"
ROOT="/opt/${APP}"
DATA="${ROOT}/data"
BIN="${ROOT}/bin"
LOG_DIR="/var/log/${APP}"
LOG="${LOG_DIR}/manager.log"

SYNC_PY="${BIN}/sync.py"
SERVER_PY="${BIN}/server.py"
CONFIG="${ROOT}/config.json"

SYNC_SERVICE="/etc/systemd/system/${APP}-sync.service"
SYNC_TIMER="/etc/systemd/system/${APP}-sync.timer"
SERVER_SERVICE="/etc/systemd/system/${APP}-subscription.service"

mkdir -p "$DATA" "$BIN" "$LOG_DIR"
chmod 700 "$ROOT" "$DATA" "$BIN" "$LOG_DIR"
touch "$LOG"
chmod 600 "$LOG"

exec > >(tee -a "$LOG") 2>&1

info() { printf '[信息] %s\n' "$*"; }
ok() { printf '[成功] %s\n' "$*"; }
warn() { printf '[警告] %s\n' "$*"; }
die() { printf '[错误] %s\n' "$*" >&2; exit 1; }

trap 'rc=$?; echo "[错误] 第 ${LINENO} 行失败，退出码 ${rc}；查看日志：'"$LOG" >&2; exit "$rc"' ERR

[[ $EUID -eq 0 ]] || die "请以 root 身份运行。"
[[ -t 0 ]] || die "首次配置需要交互终端。"

[[ -r /etc/os-release ]] || die "无法识别操作系统。"
# shellcheck disable=SC1091
source /etc/os-release

case "${ID:-}" in
  debian|ubuntu|armbian) ;;
  *) die "仅支持 Debian、Ubuntu、Armbian。" ;;
esac

export DEBIAN_FRONTEND=noninteractive

apt-get update -y
apt-get install -y curl ca-certificates python3 python3-requests \
  openssl iproute2 util-linux

# ------------------------------------------------------------
# 工具函数
# ------------------------------------------------------------

random_hex() {
    openssl rand -hex "$1"
}

find_free_port() {
    local p i
    for i in $(seq 1 300); do
        p="$(shuf -i 20000-55000 -n 1)"
        if ! ss -H -lnt 2>/dev/null |
            awk '{print $4}' |
            grep -Eq "[:.]${p}$"; then
            printf '%s\n' "$p"
            return 0
        fi
    done
    return 1
}

valid_domain() {
    [[ "$1" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,63}$ ]]
}

# ------------------------------------------------------------
# 一次性收集参数
# ------------------------------------------------------------

if [[ -f "$CONFIG" ]]; then
    read -r -p "发现现有配置。输入 R 重新配置，直接回车继续使用：" RECONFIG
else
    RECONFIG="R"
fi

if [[ "${RECONFIG^^}" == "R" ]]; then
    while true; do
        read -r -p "节点域名（例如 node.example.com）：" DOMAIN
        DOMAIN="${DOMAIN,,}"
        valid_domain "$DOMAIN" && break
        warn "域名格式不正确。"
    done

    while true; do
        read -r -p "3x-ui 管理用户名：" USERNAME
        [[ "$USERNAME" =~ ^[a-zA-Z0-9_.-]{3,64}$ ]] && break
        warn "用户名格式不正确。"
    done

    while true; do
        read -r -s -p "3x-ui 管理密码（至少 12 位）：" PASSWORD
        echo
        [[ ${#PASSWORD} -ge 12 ]] && break
        warn "密码至少 12 位。"
    done

    read -r -p "3x-ui Web Base Path（无前导斜杠，例如 abc123；默认 /）：" WEB_PATH
    WEB_PATH="${WEB_PATH#/}"
    WEB_PATH="${WEB_PATH%/}"

    if [[ -n "$WEB_PATH" ]]; then
        [[ "$WEB_PATH" =~ ^[a-zA-Z0-9_-]+$ ]] ||
            die "Web Base Path 只允许字母、数字、下划线和连字符。"
        WEB_PATH="/${WEB_PATH}/"
    else
        WEB_PATH="/"
    fi

    read -r -p "面板监听端口（已安装则输入现有端口，留空自动选择）：" PANEL_PORT
    PANEL_PORT="${PANEL_PORT:-$(find_free_port)}"
    [[ "$PANEL_PORT" =~ ^[0-9]+$ ]] &&
        ((PANEL_PORT >= 1 && PANEL_PORT <= 65535)) ||
        die "面板端口无效。"

    SUB_PORT="$(find_free_port)" || die "找不到订阅端口。"
    SUB_TOKEN="$(random_hex 24)"

    export DOMAIN USERNAME PASSWORD WEB_PATH PANEL_PORT SUB_PORT SUB_TOKEN

    python3 - "$CONFIG" <<'PY'
import json, os, sys
data = {
    "domain": os.environ["DOMAIN"],
    "username": os.environ["USERNAME"],
    "password": os.environ["PASSWORD"],
    "web_path": os.environ["WEB_PATH"],
    "panel_port": int(os.environ["PANEL_PORT"]),
    "sub_port": int(os.environ["SUB_PORT"]),
    "sub_token": os.environ["SUB_TOKEN"],
}
with open(sys.argv[1], "w") as f:
    json.dump(data, f, indent=2)
PY
    chmod 600 "$CONFIG"
fi

# 配置以 JSON 保存，避免密码中有引号或特殊字符时破坏 Shell 语法。
eval "$(
python3 - "$CONFIG" <<'PY'
import json, shlex, sys
d = json.load(open(sys.argv[1]))
for key in ("domain","username","password","web_path","panel_port","sub_port","sub_token"):
    print(f"{key.upper()}={shlex.quote(str(d[key]))}")
PY
)"

# ------------------------------------------------------------
# 安装或复用 3x-ui
# ------------------------------------------------------------

if ! command -v x-ui >/dev/null 2>&1; then
    info "未检测到 3x-ui，尝试调用官方安装器。"

    INSTALLER="$(mktemp)"
    trap 'rm -f "${INSTALLER:-}"' EXIT

    curl -fL --retry 3 \
      https://raw.githubusercontent.com/MHSanaei/3x-ui/master/install.sh \
      -o "$INSTALLER"

    bash -n "$INSTALLER" || die "官方安装器语法检查失败。"

    export XUI_NONINTERACTIVE=1
    export XUI_USERNAME="$USERNAME"
    export XUI_PASSWORD="$PASSWORD"
    export XUI_PORT="$PANEL_PORT"
    export XUI_WEB_BASE_PATH="$WEB_PATH"

    bash "$INSTALLER"
    rm -f "$INSTALLER"
    trap - ERR
else
    info "检测到已有 3x-ui，保留现有安装。"
fi

systemctl enable x-ui
systemctl restart x-ui
sleep 3
systemctl is-active --quiet x-ui || die "3x-ui 服务没有启动。"

# ------------------------------------------------------------
# Python API 同步器
# ------------------------------------------------------------

cat > "$SYNC_PY" <<'PY'
#!/usr/bin/env python3
import base64
import json
import os
import pathlib
import sys
import tempfile
import time
import requests

ROOT = pathlib.Path("/opt/xiazheteng-node-manager")
DATA = ROOT / "data"
CONFIG = ROOT / "config.json"
LINKS = DATA / "links.txt"
SUB_B64 = DATA / "subscription.txt"
STATUS = DATA / "sync-status.json"
LOG = pathlib.Path("/var/log/xiazheteng-node-manager/sync.log")

def log(message):
    stamp = time.strftime("%Y-%m-%d %H:%M:%S")
    line = f"[{stamp}] {message}"
    print(line, flush=True)
    with LOG.open("a") as f:
        f.write(line + "\n")

def atomic_write(path, content):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=str(path.parent))
    try:
        with os.fdopen(fd, "w") as f:
            f.write(content)
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)

def collect_links(obj, out):
    """兼容 allLinks 返回字符串、列表或嵌套对象的常见形式。"""
    if isinstance(obj, str):
        for line in obj.splitlines():
            line = line.strip()
            if line.startswith((
                "vless://", "vmess://", "trojan://", "ss://",
                "hysteria2://", "hy2://", "tuic://"
            )):
                out.add(line)
    elif isinstance(obj, list):
        for item in obj:
            collect_links(item, out)
    elif isinstance(obj, dict):
        for value in obj.values():
            collect_links(value, out)

def main():
    cfg = json.loads(CONFIG.read_text())
    domain = cfg["domain"]
    username = cfg["username"]
    password = cfg["password"]
    web_path = cfg["web_path"]
    port = int(cfg["panel_port"])

    base = f"http://127.0.0.1:{port}{web_path}"
    if not base.endswith("/"):
        base += "/"

    session = requests.Session()
    session.trust_env = False
    session.headers.update({"Accept": "application/json"})

    login = session.post(
        base + "login",
        data={"username": username, "password": password},
        timeout=15,
    )
    login.raise_for_status()

    try:
        login_json = login.json()
        if isinstance(login_json, dict) and login_json.get("success") is False:
            raise RuntimeError("面板 API 拒绝登录：" + str(login_json.get("msg", "")))
    except ValueError:
        pass

    endpoint = base + "panel/api/inbounds/allLinks"
    response = session.get(endpoint, timeout=30)
    response.raise_for_status()
    result = response.json()

    if not isinstance(result, dict) or result.get("success") is False:
        raise RuntimeError("allLinks API 返回失败：" + str(result))

    links = set()
    collect_links(result.get("obj"), links)
    ordered = sorted(links)

    # API 成功返回空集合也属于有效结果，可能是面板当前没有节点。
    # 请求失败时不会执行此处，不会覆盖上次有效订阅。
    plain = "".join(link + "\n" for link in ordered)
    encoded = base64.b64encode(plain.encode()).decode() if plain else ""

    atomic_write(LINKS, plain)
    atomic_write(SUB_B64, encoded + ("\n" if encoded else ""))

    status = {
        "last_sync": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "link_count": len(ordered),
        "success": True,
        "message": "同步成功",
    }
    atomic_write(STATUS, json.dumps(status, ensure_ascii=False, indent=2) + "\n")
    log(f"同步成功：发现 {len(ordered)} 条分享链接。")

if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        log("同步失败：" + repr(e))
        sys.exit(1)
PY

# ------------------------------------------------------------
# Python 订阅 HTTP 服务
# ------------------------------------------------------------

cat > "$SERVER_PY" <<'PY'
#!/usr/bin/env python3
import http.server
import json
import pathlib
import time
import urllib.parse

ROOT = pathlib.Path("/opt/xiazheteng-node-manager")
CONFIG = json.loads((ROOT / "config.json").read_text())
TOKEN = CONFIG["sub_token"]
PORT = int(CONFIG["sub_port"])
SUB = ROOT / "data" / "subscription.txt"
STATUS = ROOT / "data" / "sync-status.json"

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        path = urllib.parse.urlparse(self.path).path.strip("/")

        if path == "health":
            body = b"ok\n"
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        if path != TOKEN:
            self.send_error(404)
            return

        try:
            text = SUB.read_text().strip()
            if not text:
                self.send_error(503, "No node links available")
                return

            body = text.encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        except Exception:
            self.send_error(503, "Subscription unavailable")

    def log_message(self, *_):
        pass

http.server.ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
PY

chmod 700 "$SYNC_PY" "$SERVER_PY"

# ------------------------------------------------------------
# systemd 同步服务与定时器
# ------------------------------------------------------------

cat > "$SYNC_SERVICE" <<EOF
[Unit]
Description=${APP} API sync
After=network-online.target x-ui.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/bin/python3 ${SYNC_PY}
User=root
UMask=0077
NoNewPrivileges=true
PrivateTmp=true
EOF

cat > "$SYNC_TIMER" <<EOF
[Unit]
Description=${APP} periodic sync

[Timer]
OnBootSec=30s
OnUnitActiveSec=60s
AccuracySec=5s
Unit=${APP}-sync.service

[Install]
WantedBy=timers.target
EOF

cat > "$SERVER_SERVICE" <<EOF
[Unit]
Description=${APP} subscription server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 ${SERVER_PY}
WorkingDirectory=${ROOT}
Restart=on-failure
RestartSec=3
User=root
UMask=0077
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadOnlyPaths=${DATA}/subscription.txt ${CONFIG}

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now "${APP}-sync.timer"
systemctl enable --now "${APP}-subscription.service"

# 首次同步立即执行，不能把尚未验证的空订阅称为成功。
info "立即执行首次 API 同步。"
systemctl start "${APP}-sync.service" ||
    die "首次 API 同步失败。请检查面板登录凭据、端口、Web Base Path 与 API 路由。"

sleep 2

[[ -f "${DATA}/sync-status.json" ]] ||
    die "没有生成同步状态文件。"

python3 - "$DATA/sync-status.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
if not d.get("success"):
    raise SystemExit("同步没有成功")
print("已同步分享链接：",d.get("link_count",0))
print("同步时间：",d.get("last_sync"))
PY

# ------------------------------------------------------------
# 订阅验证与结果输出
# ------------------------------------------------------------

HTTP_CODE="$(curl -sS --max-time 10 \
  -o /dev/null -w '%{http_code}' \
  "http://127.0.0.1:${SUB_PORT}/${SUB_TOKEN}" || true)"

[[ "$HTTP_CODE" == "200" ]] ||
    die "订阅服务验证失败，HTTP ${HTTP_CODE}。"

cat > "${ROOT}/result.txt" <<EOF
域名：${DOMAIN}
面板端口：${PANEL_PORT}
订阅端口：${SUB_PORT}
订阅地址：http://${DOMAIN}:${SUB_PORT}/${SUB_TOKEN}
节点链接文件：${DATA}/links.txt
订阅文件：${DATA}/subscription.txt
同步状态：${DATA}/sync-status.json
管理日志：${LOG}
同步日志：${LOG_DIR}/sync.log
同步间隔：60 秒
EOF
chmod 600 "${ROOT}/result.txt"

printf '\n'
printf '%s\n' '============================================================'
printf '%s\n' '               部署与同步配置完成'
printf '%s\n' '============================================================'
printf '订阅地址：http://%s:%s/%s\n' "$DOMAIN" "$SUB_PORT" "$SUB_TOKEN"
printf '结果文件：%s/result.txt\n' "$ROOT"
printf '节点列表：%s\n' "$DATA/links.txt"
printf '同步周期：每 60 秒\n'
printf '\n'
warn "本脚本的订阅端点使用 HTTP。请勿在不可信网络中公开传输订阅令牌。"
warn "请在云厂商安全组放行订阅端口，以及实际节点监听端口。"
warn "此脚本负责扫描和同步现有节点，不会在首次安装时自动创建所有协议节点。"
warn "如果面板使用自签证书或非标准 Web Base Path，请先确认本机 API 登录成功。"
