
#!/usr/bin/env bash
# ============================================================
# 瞎折腾吧 | 3x-ui 自动节点管理器
# 目标：Ubuntu / Debian + 3x-ui v3.x
# YouTube: https://www.youtube.com/@xiazheteng8
# Telegram: https://t.me/xiazheteng8
#
# 功能：
#   1. 自动读取 x-ui.db 中的面板配置
#   2. 自动识别 Web Base Path、端口和登录凭据
#   3. 自动生成 VLESS + REALITY 节点
#   4. 自动选择空闲端口
#   5. 自动生成分享链接和 Base64 订阅
#   6. 不删除、不重置已有节点和面板配置
#
# 注意：如果无法可靠读取凭据或 API 认证失败，会安全退出。
# ============================================================

set -Eeuo pipefail
umask 077

APP="xiazheteng-node-manager"
BASE="/etc/$APP"
DATA="$BASE/data"
NODE_FILE="$DATA/nodes.txt"
SUB_FILE="$DATA/subscription.txt"
INFO_FILE="$DATA/node.env"
BACKUP_DIR="$BASE/backup"

DB="/etc/x-ui/x-ui.db"
XRAY=""
PANEL_PORT=""
BASE_PATH=""
PANEL_USER=""
PANEL_PASS=""
PUBLIC_IP=""
NODE_PORT=""
UUID=""
PRIVATE_KEY=""
PUBLIC_KEY=""
SHORT_ID=""
SNI="www.microsoft.com"
REMARK="瞎折腾吧-REALITY"
COOKIE="$(mktemp)"
WORK="$(mktemp -d)"

info(){ printf '\033[1;34m[信息]\033[0m %s\n' "$*"; }
ok(){ printf '\033[1;32m[成功]\033[0m %s\n' "$*"; }
warn(){ printf '\033[1;33m[提示]\033[0m %s\n' "$*"; }
die(){ printf '\033[1;31m[错误]\033[0m %s\n' "$*" >&2; exit 1; }

cleanup(){
  rm -f "$COOKIE"
  rm -rf "$WORK"
}
trap cleanup EXIT

[[ $EUID -eq 0 ]] || die "请使用 root 权限运行。"
[[ -f "$DB" ]] || die "未找到数据库：$DB"
command -v python3 >/dev/null 2>&1 || die "缺少 python3。"
command -v curl >/dev/null 2>&1 || die "缺少 curl。"
command -v openssl >/dev/null 2>&1 || die "缺少 openssl。"
command -v ss >/dev/null 2>&1 || die "缺少 ss。"

mkdir -p "$DATA" "$BACKUP_DIR"
chmod 700 "$BASE" "$DATA" "$BACKUP_DIR"

# ------------------------------------------------------------
# 1. 自动识别数据库配置
# ------------------------------------------------------------

info "正在读取 3x-ui 数据库结构……"

python3 - "$DB" "$WORK/db.env" <<'PY'
import sqlite3, sys, os, re

db, out = sys.argv[1:]
con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
con.row_factory = sqlite3.Row
tables = [
    r["name"] for r in con.execute(
        "SELECT name FROM sqlite_master WHERE type='table'"
    )
]

values = {}

# 兼容常见 key/value 设置表结构。
for table in tables:
    try:
        cols = [r["name"] for r in con.execute(
            f'PRAGMA table_info("{table}")'
        )]
    except Exception:
        continue

    lower = {c.lower(): c for c in cols}

    if "key" in lower and "value" in lower:
        try:
            rows = con.execute(
                f'SELECT "{lower["key"]}", "{lower["value"]}" FROM "{table}"'
            )
            for row in rows:
                if row[0] is not None and row[1] is not None:
                    values[str(row[0]).lower()] = str(row[1])
        except Exception:
            pass

    # 某些版本把面板用户放在独立 users 表中。
    if "username" in lower and "password" in lower:
        try:
            row = con.execute(
                f'SELECT "{lower["username"]}", "{lower["password"]}" '
                f'FROM "{table}" LIMIT 1'
            ).fetchone()
            if row:
                values.setdefault("username", str(row[0] or ""))
                values.setdefault("password", str(row[1] or ""))
        except Exception:
            pass

def first(*keys):
    for key in keys:
        val = values.get(key.lower(), "")
        if val != "":
            return val
    return ""

port = first("webPort", "webport", "web_port", "port")
base = first("webBasePath", "webbasepath", "web_base_path", "basePath")
user = first("username", "webUser", "webUsername")
password = first("password", "webPass", "webPassword")

# 只接受合法端口。
try:
    port = int(port)
    if not 1 <= port <= 65535:
        raise ValueError()
except Exception:
    port = ""

# Base Path 规范化为以 / 开头、以 / 结尾。
base = (base or "").strip()
if base and not base.startswith("/"):
    base = "/" + base
if base and not base.endswith("/"):
    base += "/"

def q(v):
    return "'" + str(v).replace("'", "'\\''") + "'"

with open(out, "w", encoding="utf-8") as f:
    f.write(f"PANEL_PORT={q(port)}\n")
    f.write(f"BASE_PATH={q(base)}\n")
    f.write(f"PANEL_USER={q(user)}\n")
    f.write(f"PANEL_PASS={q(password)}\n")

print("发现数据库表：", ", ".join(tables))
print("面板端口：", port if port else "无法可靠识别")
print("Base Path：", base if base else "(根路径)")
print("用户名：", "已识别" if user else "未识别")
print("密码字段：", "已识别" if password else "未识别")
con.close()
PY

# 数据库导出文件由本机 Python 生成，只包含 shell 赋值。
# shellcheck disable=SC1090
source "$WORK/db.env"

[[ -n "$PANEL_PORT" ]] || die \
  "无法从数据库可靠识别面板端口。为保护现有环境，未修改任何配置。"

if [[ -z "$PANEL_USER" || -z "$PANEL_PASS" ]]; then
  die "无法从数据库可靠读取面板用户名或密码。脚本不会猜测凭据或重置密码。请先核实当前版本的数据库字段结构。"
fi

info "面板地址将使用本机 HTTP 和数据库识别出的 Base Path。"

# ------------------------------------------------------------
# 2. 定位 Xray
# ------------------------------------------------------------

for candidate in \
  /usr/local/x-ui/bin/xray-linux-amd64 \
  /usr/local/x-ui/bin/xray \
  /usr/local/bin/xray \
  /usr/bin/xray
do
  if [[ -x "$candidate" ]]; then
    XRAY="$candidate"
    break
  fi
done

if [[ -z "$XRAY" ]]; then
  XRAY="$(command -v xray || true)"
fi

[[ -n "$XRAY" && -x "$XRAY" ]] || die \
  "没有找到可执行的 Xray。请检查 3x-ui 安装目录。"

# ------------------------------------------------------------
# 3. 自动检测面板登录路径
# ------------------------------------------------------------

API_ROOT="http://127.0.0.1:${PANEL_PORT}${BASE_PATH}"

info "正在自动验证面板 API……"

LOGIN_HTTP="$(
  curl -sS --connect-timeout 5 --max-time 15 \
    -o "$WORK/login.body" \
    -w '%{http_code}' \
    -c "$COOKIE" -b "$COOKIE" \
    -X POST "${API_ROOT}login" \
    --data-urlencode "username=${PANEL_USER}" \
    --data-urlencode "password=${PANEL_PASS}" \
    || true
)"

if [[ "$LOGIN_HTTP" != "200" ]]; then
  warn "面板登录 HTTP 状态：${LOGIN_HTTP:-连接失败}"
  if [[ "$LOGIN_HTTP" == "403" ]]; then
    die "面板返回 403。可能是 Base Path、访问策略或认证机制不匹配；未修改面板、数据库或已有节点。"
  elif [[ "$LOGIN_HTTP" == "404" ]]; then
    die "登录地址返回 404。数据库中的 Base Path 与实际路由可能不一致；未修改现有配置。"
  else
    die "面板 API 登录未成功。响应已保存在临时目录中，脚本退出时会清理。"
  fi
fi

if ! grep -Eqi '"success"[[:space:]]*:[[:space:]]*true' "$WORK/login.body"; then
  warn "HTTP 返回 200，但响应未明确表示登录成功。"
  die "为避免向未认证的 API 写入数据，已停止。"
fi

ok "面板 API 登录成功。"

# ------------------------------------------------------------
# 4. 自动选择空闲端口
# ------------------------------------------------------------

port_used(){
  ss -H -lnt 2>/dev/null |
    awk '{print $4}' |
    grep -Eq "(:|\\])${1}$"
}

NODE_PORT=""
for _ in $(seq 1 200); do
  p="$(shuf -i 20000-60000 -n 1)"
  if ! port_used "$p"; then
    NODE_PORT="$p"
    break
  fi
done

[[ -n "$NODE_PORT" ]] || die "无法找到空闲端口。"

# ------------------------------------------------------------
# 5. 自动获取公网 IPv4
# ------------------------------------------------------------

for url in \
  https://api.ipify.org \
  https://ipv4.icanhazip.com \
  https://ifconfig.me/ip
do
  PUBLIC_IP="$(curl -4 -fsS --connect-timeout 5 --max-time 10 "$url" 2>/dev/null | tr -d '[:space:]' || true)"
  if python3 - "$PUBLIC_IP" <<'PY' >/dev/null 2>&1
import ipaddress,sys
ipaddress.IPv4Address(sys.argv[1])
PY
  then
    break
  fi
  PUBLIC_IP=""
done

[[ -n "$PUBLIC_IP" ]] || die "无法自动获取公网 IPv4。"

# ------------------------------------------------------------
# 6. 生成 REALITY 密钥，兼容多种 Xray 输出格式
# ------------------------------------------------------------

info "正在生成 REALITY 密钥……"

KEY_OUTPUT="$("$XRAY" x25519 2>&1)" ||
  die "执行 Xray x25519 失败。"

KEYS="$(
  printf '%s\n' "$KEY_OUTPUT" |
  awk '
  {
    line=$0
    pos=index(line, ":")
    if (!pos) next

    label=substr(line,1,pos-1)
    value=substr(line,pos+1)
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", label)
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)

    normalized=tolower(label)
    gsub(/[^a-z]/, "", normalized)

    if (normalized=="privatekey" || normalized=="private") {
      private=value
    }

    if (normalized=="publickey" ||
        normalized=="password" ||
        normalized=="passwordpublickey") {
      if (value ~ /^[A-Za-z0-9_-]+$/) public=value
    }
  }
  END {
    if (private!="" && public!="")
      print private "|" public
  }'
)"

[[ "$KEYS" == *"|"* ]] || {
  err "无法解析 Xray x25519 输出格式。"
  printf '%s\n' "$KEY_OUTPUT" |
    sed -E 's/^([[:space:]]*[Pp]rivate[^:]*:).*/\1 <已隐藏>/'
  die "密钥解析失败，未创建节点。"
}

PRIVATE_KEY="${KEYS%%|*}"
PUBLIC_KEY="${KEYS#*|}"

UUID="$(cat /proc/sys/kernel/random/uuid)"
SHORT_ID="$(openssl rand -hex 8)"

# ------------------------------------------------------------
# 7. 创建 VLESS + REALITY 入站
# ------------------------------------------------------------

# 先确认 API 列表路由能访问，避免把错误路由误当成认证成功。
LIST_HTTP="$(
  curl -sS --connect-timeout 5 --max-time 15 \
    -o "$WORK/list.body" \
    -w '%{http_code}' \
    -c "$COOKIE" -b "$COOKIE" \
    "${API_ROOT}panel/api/inbounds/list" || true
)"

if [[ "$LIST_HTTP" != "200" ]]; then
  die "入站列表 API 返回 HTTP ${LIST_HTTP:-连接失败}。已停止，未添加节点。"
fi

if ! grep -Eqi '"success"[[:space:]]*:[[:space:]]*true' "$WORK/list.body"; then
  die "入站列表 API 未确认成功。为避免重复创建，已停止。"
fi

# 生成 JSON，避免 shell 手动拼接嵌套 JSON。
python3 - "$WORK/inbound.json" "$UUID" "$NODE_PORT" \
  "$PRIVATE_KEY" "$SHORT_ID" "$SNI" "$REMARK" <<'PY'
import json,sys
out,uid,port,private,sid,sni,remark=sys.argv[1:]
settings={
    "clients":[{"id":uid,"flow":"xtls-rprx-vision","email":remark}],
    "decryption":"none",
    "fallbacks":[]
}
stream={
    "network":"raw",
    "security":"reality",
    "realitySettings":{
        "show":False,
        "dest":sni+":443",
        "xver":0,
        "serverNames":[sni],
        "privateKey":private,
        "shortIds":[sid]
    }
}
obj={
    "up":0,
    "down":0,
    "total":0,
    "remark":remark,
    "enable":True,
    "expiryTime":0,
    "listen":"0.0.0.0",
    "port":int(port),
    "protocol":"vless",
    "settings":json.dumps(settings,separators=(",",":")),
    "streamSettings":json.dumps(stream,separators=(",",":")),
    "sniffing":json.dumps({
        "enabled":True,
        "destOverride":["http","tls","quic"]
    },separators=(",",":"))
}
with open(out,"w",encoding="utf-8") as f:
    json.dump(obj,f,separators=(",",":"))
PY

info "正在通过 3x-ui API 创建节点……"

ADD_HTTP="$(
  python3 - "$WORK/inbound.json" <<'PY' |
import json,sys,urllib.parse
obj=json.load(open(sys.argv[1],encoding="utf-8"))
print(urllib.parse.urlencode(obj))
PY
  curl -sS --connect-timeout 5 --max-time 20 \
    -o "$WORK/add.body" \
    -w '%{http_code}' \
    -c "$COOKIE" -b "$COOKIE" \
    -X POST "${API_ROOT}panel/api/inbounds/add" \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    --data-binary @- \
    || true
)"

if [[ "$ADD_HTTP" != "200" ]] ||
   ! grep -Eqi '"success"[[:space:]]*:[[:space:]]*true' "$WORK/add.body"; then
  warn "节点创建请求未获得成功响应。"
  warn "HTTP 状态：${ADD_HTTP:-连接失败}"
  warn "请检查 3x-ui 日志；脚本不会删除已有节点或自动重置面板。"
  die "API 未确认新节点创建成功。"
fi

# ------------------------------------------------------------
# 8. 生成分享链接与订阅
# ------------------------------------------------------------

LINK="$(
python3 - "$PUBLIC_IP" "$NODE_PORT" "$UUID" "$PUBLIC_KEY" \
  "$SHORT_ID" "$SNI" "$REMARK" <<'PY'
import sys,urllib.parse
ip,port,uid,pbk,sid,sni,remark=sys.argv[1:]
params={
  "encryption":"none",
  "flow":"xtls-rprx-vision",
  "security":"reality",
  "sni":sni,
  "fp":"chrome",
  "pbk":pbk,
  "sid":sid,
  "type":"tcp"
}
print(
  f"vless://{uid}@{ip}:{port}?"
  f"{urllib.parse.urlencode(params)}"
  f"#{urllib.parse.quote(remark,safe='')}"
)
PY
)"

printf '%s\n' "$LINK" >> "$NODE_FILE"
awk 'NF && !seen[$0]++' "$NODE_FILE" > "$WORK/nodes.txt"
install -m 600 "$WORK/nodes.txt" "$NODE_FILE"

base64 -w 0 "$NODE_FILE" > "$SUB_FILE"
printf '\n' >> "$SUB_FILE"
chmod 600 "$SUB_FILE"

cat > "$INFO_FILE" <<EOF
PUBLIC_IP='$PUBLIC_IP'
PORT='$NODE_PORT'
UUID='$UUID'
PUBLIC_KEY='$PUBLIC_KEY'
SHORT_ID='$SHORT_ID'
SNI='$SNI'
EOF
chmod 600 "$INFO_FILE"

# ------------------------------------------------------------
# 9. 最终输出
# ------------------------------------------------------------

ok "VLESS + REALITY 节点已由 3x-ui API 创建。"

echo
echo "================ 部署结果 ================"
echo "面板版本：      3x-ui v3.x（已通过 API 验证）"
echo "服务器 IPv4：   $PUBLIC_IP"
echo "节点端口：      $NODE_PORT"
echo "UUID：          $UUID"
echo "REALITY 公钥：  $PUBLIC_KEY"
echo "Short ID：      $SHORT_ID"
echo
echo "分享链接："
echo "$LINK"
echo
echo "本地订阅文件："
echo "$SUB_FILE"
echo
echo "节点记录："
echo "$NODE_FILE"
echo
echo "请确认云服务商安全组放行 TCP $NODE_PORT。"
echo "==========================================="
