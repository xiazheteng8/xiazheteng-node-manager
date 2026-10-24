
#!/usr/bin/env bash
# ============================================================
# 瞎折腾吧 VPS 节点自动部署管理器
# 独立 Xray 实例 | 环境检测 | 端口避让 | 在线订阅 | CF Tunnel | 安全卸载
# ============================================================

set -Eeuo pipefail
umask 077

APP="xiazheteng-node-manager"
BASE="/opt/xiazheteng-node"
BIN="$BASE/bin/xray"
CONF="$BASE/config.json"
DATA="$BASE/data"
LOGDIR="/var/log/$APP"
LOG="$LOGDIR/manager.log"
ENVFILE="$BASE/settings.env"
MANIFEST="$BASE/managed-files.txt"
SERVICE="xiazheteng-xray"
UNIT="/etc/systemd/system/$SERVICE.service"
SUB_SERVICE="xiazheteng-subscription"
SUB_UNIT="/etc/systemd/system/$SUB_SERVICE.service"
SUB_SERVER="$BASE/subscription_server.py"
SUB_TOKEN_FILE="$DATA/subscription.token"
SUB_PORT_FILE="$DATA/subscription-port.env"
SUB_URL_FILE="$DATA/subscription-url.txt"
SUBFILE="$DATA/subscription.txt"
SUBJSON="$DATA/nodes.json"
SHORTCUT="/usr/local/bin/x"
XRAY_REPO="XTLS/Xray-core"
CF_CONF="$BASE/cf-tunnel-xray.json"
CF_SERVICE="xiazheteng-cf-xray"
CF_UNIT="/etc/systemd/system/$CF_SERVICE.service"
CF_TUNNEL_SERVICE="xiazheteng-cloudflared"
CF_TUNNEL_UNIT="/etc/systemd/system/$CF_TUNNEL_SERVICE.service"
CF_SETTINGS="$DATA/cf-tunnel-settings.env"
CF_TOKEN_FILE="$DATA/cloudflared-token.env"
CLOUDFLARED_BIN="/usr/local/bin/cloudflared"

mkdir -p "$LOGDIR"
touch "$LOG"
chmod 600 "$LOG"

log() {
    printf '[%s] [%s] %s\n' \
        "$(date '+%F %T')" "$1" "$2" | tee -a "$LOG"
}
info() { log INFO "$*"; }
warn() { log WARN "$*"; }
err()  { log ERROR "$*"; }
die()  { err "$*"; exit 1; }

trap 'rc=$?; err "命令执行失败，退出码=$rc，行号=${LINENO}。请检查 $LOG"; exit "$rc"' ERR

need_root() {
    [[ $EUID -eq 0 ]] || {
        echo "请使用 root 运行：sudo bash $0"
        exit 1
    }
}

# -------------------- 环境检测 --------------------

detect_os() {
    [[ -r /etc/os-release ]] || die "无法识别操作系统。"
    . /etc/os-release

    case "${ID:-}" in
        debian|ubuntu) ;;
        *) die "当前系统 ${ID:-unknown} 不在自动部署支持列表中。" ;;
    esac

    command -v systemctl >/dev/null ||
        die "未检测到 systemd。"

    case "$(uname -m)" in
        x86_64|amd64) ARCH="64" ;;
        aarch64|arm64) ARCH="arm64-v8a" ;;
        *) die "不支持的 CPU 架构：$(uname -m)" ;;
    esac

    info "系统：${PRETTY_NAME:-$ID}，架构：$(uname -m)"
}

install_dependencies() {
    local missing=()
    for c in curl jq openssl python3 ss base64; do
        command -v "$c" >/dev/null 2>&1 || missing+=("$c")
    done

    if ((${#missing[@]})); then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -y
        apt-get install -y curl jq openssl python3 iproute2 ca-certificates
    fi

    for c in curl jq openssl python3 ss; do
        command -v "$c" >/dev/null 2>&1 ||
            die "依赖安装后仍缺少命令：$c"
    done
}

detect_public_ipv4() {
    PUBLIC_IP=""
    local ip
    for url in \
        https://api.ipify.org \
        https://ipv4.icanhazip.com \
        https://ifconfig.me/ip; do
        ip="$(curl -4 -fsS --connect-timeout 3 --max-time 6 "$url" 2>/dev/null || true)"
        if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            PUBLIC_IP="$ip"
            break
        fi
    done

    if [[ -z "$PUBLIC_IP" ]]; then
        warn "无法获取公网 IPv4；尝试从本地路由获取地址。"
        PUBLIC_IP="$(ip -4 route get 1.1.1.1 2>/dev/null |
            awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}' || true)"
    fi

    [[ -n "$PUBLIC_IP" ]] || die "无法确定 IPv4 地址。"
    info "检测到 IPv4：$PUBLIC_IP"
}

check_domain() {
    DOMAIN_OK=0
    [[ -n "${DOMAIN:-}" ]] || return 0

    if [[ "$DOMAIN" =~ [^a-zA-Z0-9.-] ]] ||
       [[ "$DOMAIN" == *..* ]] ||
       [[ "$DOMAIN" == .* ]] ||
       [[ "$DOMAIN" == *. ]]; then
        warn "域名格式不合法，将切换到无域名模式。"
        DOMAIN=""
        return 0
    fi

    local ips
    ips="$(getent ahostsv4 "$DOMAIN" 2>/dev/null |
        awk '{print $1}' | sort -u || true)"

    if [[ -z "$ips" ]]; then
        warn "$DOMAIN 没有可查询到的 IPv4 A 记录；跳过 TLS 证书申请及 TLS 节点。请确认 DNS 已生效。"
        return 0
    fi

    if ! grep -Fxq "$PUBLIC_IP" <<< "$ips"; then
        warn "$DOMAIN 的 A 记录为：$(tr '\n' ' ' <<< "$ips")；不包含本机公网 IPv4 $PUBLIC_IP，跳过 TLS 节点。请检查 DNS/CDN 与源站配置。"
        return 0
    fi

    DOMAIN_OK=1
    info "域名解析检查通过：$DOMAIN"
}

# -------------------- 端口与已有服务检测 --------------------

port_in_use() {
    ss -H -lnt "( sport = :$1 )" 2>/dev/null | grep -q .
}

choose_port() {
    local p
    for p in "$@"; do
        # 在线订阅端口作为保留端口，不能再次分配给 Xray。
        [[ "${SUB_PORT:-}" == "$p" ]] && continue
        if ! port_in_use "$p"; then
            echo "$p"
            return 0
        fi
    done
    return 1
}

choose_random_port() {
    local i p
    for i in $(seq 1 150); do
        p="$(shuf -i 20000-60000 -n 1)"
        [[ "${SUB_PORT:-}" == "$p" ]] && continue
        if ! port_in_use "$p"; then
            echo "$p"
            return 0
        fi
    done
    return 1
}

inspect_existing_services() {
    info "检查现有代理、面板及 Web 服务。"
    local svc
    for svc in x-ui 3x-ui sing-box xray nginx apache2 caddy haproxy; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            info "检测到运行中的服务：$svc（不会停止或覆盖）"
        fi
    done

    ss -lntp 2>/dev/null | tee -a "$LOG" >/dev/null || true
}

# -------------------- Xray 安装 --------------------

install_xray() {
    if [[ -x "$BIN" ]] && "$BIN" version >/dev/null 2>&1; then
        info "检测到本脚本已有 Xray，跳过重复安装。"
        return
    fi

    mkdir -p "$BASE/bin" "$DATA"

    local api tag url tmp
    api="https://api.github.com/repos/$XRAY_REPO/releases/latest"
    tag="$(curl -fsSL --retry 3 --max-time 30 "$api" |
        jq -r '.tag_name // empty')"
    [[ -n "$tag" ]] || die "无法获取 Xray 发行版本。"

    case "$ARCH" in
        64) url="https://github.com/$XRAY_REPO/releases/download/$tag/Xray-linux-64.zip" ;;
        arm64-v8a) url="https://github.com/$XRAY_REPO/releases/download/$tag/Xray-linux-arm64-v8a.zip" ;;
        *) die "不支持的 Xray 架构。" ;;
    esac

    tmp="$(mktemp -d)"
    info "下载 Xray：$tag"

    if ! curl -fL --retry 3 --connect-timeout 10 --max-time 180 \
        "$url" -o "$tmp/xray.zip"; then
        rm -rf "$tmp"
        die "Xray 下载失败。"
    fi

    apt-get install -y unzip >/dev/null
    unzip -oq "$tmp/xray.zip" -d "$tmp/unpack"

    [[ -f "$tmp/unpack/xray" ]] || {
        rm -rf "$tmp"
        die "发行包中没有找到 xray 二进制。"
    }

    install -m 0755 "$tmp/unpack/xray" "$tmp/xray-test"
    "$tmp/xray-test" version >/dev/null ||
        die "下载的 Xray 无法执行。"

    install -m 0755 "$tmp/unpack/xray" "$BIN"
    rm -rf "$tmp"
    info "Xray 安装完成：$("$BIN" version | head -n 1)"
}

# -------------------- REALITY 密钥 --------------------

generate_reality_keys() {
    local output line label value
    PRIVATE_KEY=""
    PUBLIC_KEY=""

    if ! output="$("$BIN" x25519 2>&1)"; then
        warn "Xray x25519 密钥生成失败：$output"
        return 0
    fi

    # 兼容不同 Xray 版本的密钥标签与大小写格式。
    while IFS= read -r line; do
        [[ "$line" == *:* ]] || continue
        label="${line%%:*}"
        value="${line#*:}"
        value="$(printf '%s' "$value" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        label="$(printf '%s' "$label" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
        case "$label" in
            privatekey|private)
                [[ -n "$value" ]] && PRIVATE_KEY="$value"
                ;;
            password|publickey|public)
                [[ -n "$value" ]] && PUBLIC_KEY="$value"
                ;;
        esac
    done <<< "$output"

    # 兼容标签未知但按私钥、公钥顺序输出的版本。
    if [[ -z "$PRIVATE_KEY" || -z "$PUBLIC_KEY" ]]; then
        local -a values=()
        while IFS= read -r line; do
            [[ "$line" == *:* ]] || continue
            value="${line#*:}"
            value="$(printf '%s' "$value" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
            [[ -n "$value" ]] && values+=("$value")
        done <<< "$output"
        [[ -n "$PRIVATE_KEY" ]] || PRIVATE_KEY="${values[0]:-}"
        [[ -n "$PUBLIC_KEY" ]] || PUBLIC_KEY="${values[1]:-}"
    fi

    if [[ -z "$PRIVATE_KEY" || -z "$PUBLIC_KEY" ]]; then
        warn "无法识别 Xray x25519 输出中的密钥，REALITY 节点将被跳过。原始输出：$output"
        PRIVATE_KEY=""
        PUBLIC_KEY=""
        return 0
    fi
    info "REALITY 密钥生成并解析成功。"
}

# -------------------- TLS 证书 --------------------

obtain_tls_certificate() {
    TLS_OK=0
    [[ "${DOMAIN_OK:-0}" == 1 ]] || return 0

    if port_in_use 80; then
        warn "TCP 80 已被占用；不会停止现有服务，跳过自动 TLS 证书申请。"
        return 0
    fi

    local email
    email="admin@$DOMAIN"

    if [[ ! -x "$HOME/.acme.sh/acme.sh" ]]; then
        curl -fsSL --retry 2 --max-time 60 \
            https://get.acme.sh -o "$BASE/acme-install.sh" || {
            warn "无法下载 acme.sh，跳过 TLS。"
            return 0
        }

        sh "$BASE/acme-install.sh" email="$email" || {
            warn "acme.sh 安装失败，跳过 TLS。"
            return 0
        }
    fi

    local acme="$HOME/.acme.sh/acme.sh"
    [[ -x "$acme" ]] || {
        warn "找不到 acme.sh，跳过 TLS。"
        return 0
    }

    "$acme" --issue --standalone -d "$DOMAIN" \
        --server letsencrypt --keylength ec-256 --force || {
        warn "证书签发失败；保留其他节点，跳过 TLS 节点。"
        return 0
    }

    mkdir -p "$BASE/certs"
    chmod 700 "$BASE/certs"

    "$acme" --install-cert -d "$DOMAIN" --ecc \
        --key-file "$BASE/certs/key.pem" \
        --fullchain-file "$BASE/certs/fullchain.pem" \
        --reloadcmd "systemctl restart $SERVICE 2>/dev/null || true" || {
        warn "证书安装失败，跳过 TLS 节点。"
        return 0
    }

    chmod 600 "$BASE/certs/"*.pem
    TLS_OK=1
    info "TLS 证书安装完成。"
}

# -------------------- 在线订阅端口 --------------------

setup_subscription_port() {
    mkdir -p "$DATA"

    # 已有在线订阅配置则复用，避免每次安装更换 URL。
    if [[ -f "$SUB_PORT_FILE" ]]; then
        # shellcheck disable=SC1090
        source "$SUB_PORT_FILE"
        if [[ "${SUB_PORT:-}" =~ ^[0-9]+$ ]] &&
           [[ "$SUB_PORT" -ge 1 && "$SUB_PORT" -le 65535 ]] &&
           ! port_in_use "$SUB_PORT"; then
            info "复用订阅端口：$SUB_PORT"
            return 0
        fi
    fi

    SUB_PORT=""
    if [[ "${TLS_OK:-0}" == 1 ]]; then
        SUB_PORT="$(choose_port 443 8443 9443 10443 18443 || true)"
    fi

    if [[ -z "$SUB_PORT" ]]; then
        SUB_PORT="$(choose_port 18080 18081 18082 28080 38080 || true)"
    fi

    if [[ -z "$SUB_PORT" ]]; then
        SUB_PORT="$(choose_random_port)" ||
            die "无法为在线订阅服务选择可用端口。"
    fi

    printf 'SUB_PORT=%q\n' "$SUB_PORT" > "$SUB_PORT_FILE"
    chmod 600 "$SUB_PORT_FILE"
    info "在线订阅服务端口：$SUB_PORT"
}

# -------------------- Xray 配置生成 --------------------

generate_configuration() {
    local reality_port ss_port tls_port
    local uuid ss_password short_id

    reality_port="$(choose_port 443 8443 2053 2083 2087 2096 2443 10443 \
        || choose_random_port)" || die "无法为 REALITY 选择端口。"

    ss_port="$(choose_port 8388 8389 8390 18444 28443 \
        || choose_random_port)" || die "无法为 Shadowsocks 选择端口。"

    tls_port=""
    if [[ "${TLS_OK:-0}" == 1 ]]; then
        tls_port="$(choose_port 10444 1443 2443 3443 4443 \
            || choose_random_port)" || {
            warn "无可用 TLS 端口，跳过 TLS 节点。"
            TLS_OK=0
        }
    fi

    uuid="$(cat /proc/sys/kernel/random/uuid)"
    ss_password="$(openssl rand -base64 24 | tr -d '\n')"
    short_id="$(openssl rand -hex 8)"

    generate_reality_keys

    export BASE REALITY_PORT="$reality_port" SS_PORT="$ss_port"
    export TLS_PORT="${tls_port:-0}" NODE_UUID="$uuid"
    export SS_PASSWORD="$ss_password" SHORT_ID="$short_id"
    export PRIVATE_KEY="${PRIVATE_KEY:-}" PUBLIC_KEY="${PUBLIC_KEY:-}"
    export DOMAIN="${DOMAIN:-}" PUBLIC_IP

    python3 - <<'PY'
import json, os

base = os.environ["BASE"]
domain = os.environ.get("DOMAIN", "")
ip = os.environ["PUBLIC_IP"]
uuid = os.environ["NODE_UUID"]
short_id = os.environ["SHORT_ID"]
private_key = os.environ.get("PRIVATE_KEY", "")
public_key = os.environ.get("PUBLIC_KEY", "")
reality_port = int(os.environ["REALITY_PORT"])
ss_port = int(os.environ["SS_PORT"])
tls_port = int(os.environ["TLS_PORT"])
ss_password = os.environ["SS_PASSWORD"]

inbounds = []

if private_key and public_key:
    inbounds.append({
        "tag": "in-reality",
        "listen": "0.0.0.0",
        "port": reality_port,
        "protocol": "vless",
        "settings": {
            "clients": [{"id": uuid, "flow": "xtls-rprx-vision"}],
            "decryption": "none"
        },
        "streamSettings": {
            "network": "raw",
            "security": "reality",
            "realitySettings": {
                "show": False,
                "dest": "www.microsoft.com:443",
                "xver": 0,
                "serverNames": ["www.microsoft.com"],
                "privateKey": private_key,
                "shortIds": [short_id]
            }
        }
    })

inbounds.append({
    "tag": "in-shadowsocks",
    "listen": "0.0.0.0",
    "port": ss_port,
    "protocol": "shadowsocks",
    "settings": {
        "method": "chacha20-ietf-poly1305",
        "password": ss_password,
        "network": "tcp,udp"
    }
})

if tls_port and domain and os.path.isfile(base + "/certs/fullchain.pem") \
        and os.path.isfile(base + "/certs/key.pem"):
    inbounds.append({
        "tag": "in-vless-ws-tls",
        "listen": "0.0.0.0",
        "port": tls_port,
        "protocol": "vless",
        "settings": {"clients": [{"id": uuid}], "decryption": "none"},
        "streamSettings": {
            "network": "ws",
            "security": "tls",
            "tlsSettings": {
                "alpn": ["http/1.1"],
                "certificates": [{
                    "certificateFile": base + "/certs/fullchain.pem",
                    "keyFile": base + "/certs/key.pem"
                }]
            },
            "wsSettings": {"path": "/xws"}
        }
    })

config = {
    "log": {"loglevel": "warning"},
    "inbounds": inbounds,
    "outbounds": [{"protocol": "freedom", "tag": "direct"}]
}

path = base + "/config.json"
tmp = path + ".tmp"
with open(tmp, "w") as f:
    json.dump(config, f, indent=2)
os.chmod(tmp, 0o600)
os.replace(tmp, path)

# 保留独立部署的 Cloudflare Tunnel 节点，避免重新生成普通节点时将其覆盖。
nodes_path = base + "/data/nodes.json"
preserved_cf_nodes = []
if os.path.isfile(nodes_path):
    try:
        with open(nodes_path, "r") as f:
            old_nodes = json.load(f)
        if isinstance(old_nodes, list):
            preserved_cf_nodes = [n for n in old_nodes
                                  if isinstance(n, dict) and n.get("type") == "vless-ws-cf-tunnel"]
    except (OSError, json.JSONDecodeError):
        pass
nodes = list(preserved_cf_nodes)
if private_key and public_key:
    nodes.append({
        "type": "vless-reality",
        "address": ip,
        "port": reality_port,
        "uuid": uuid,
        "flow": "xtls-rprx-vision",
        "security": "reality",
        "public_key": public_key,
        "short_id": short_id,
        "sni": "www.microsoft.com"
    })

nodes.append({
    "type": "shadowsocks",
    "address": ip,
    "port": ss_port,
    "method": "chacha20-ietf-poly1305",
    "password": ss_password
})

if any(x["tag"] == "in-vless-ws-tls" for x in inbounds):
    nodes.append({
        "type": "vless-ws-tls",
        "address": domain,
        "port": tls_port,
        "uuid": uuid,
        "path": "/xws",
        "sni": domain
    })

with open(base + "/data/nodes.json", "w") as f:
    json.dump(nodes, f, indent=2)
os.chmod(base + "/data/nodes.json", 0o600)
PY

    echo "$reality_port" > "$DATA/reality.port"
    echo "$ss_port" > "$DATA/shadowsocks.port"
    [[ -n "$tls_port" ]] && echo "$tls_port" > "$DATA/tls.port" || true
}

# -------------------- 订阅内容生成 --------------------

generate_subscription() {
    [[ -f "$SUBJSON" ]] || {
        warn "没有节点清单；请先执行安装。"
        return 1
    }

    "$BIN" run -test -config "$CONF" >/dev/null 2>&1 || {
        warn "主 Xray 配置验证失败，不生成订阅。"
        return 1
    }
    if [[ -f "$CF_CONF" ]]; then
        "$BIN" run -test -config "$CF_CONF" >/dev/null 2>&1 || {
            warn "CF Tunnel 专用 Xray 配置验证失败，不生成订阅。"
            return 1
        }
    fi

    python3 - <<'PY'
import base64, json, os, urllib.parse

base = "/opt/xiazheteng-node"
with open(base + "/data/nodes.json") as f:
    nodes = json.load(f)

links = []
for n in nodes:
    t = n["type"]
    name = urllib.parse.quote("xiazheteng-" + t, safe="")
    host = n["address"]
    port = n["port"]

    if t == "vless-reality":
        if not n.get("public_key") or not n.get("uuid"):
            continue
        q = urllib.parse.urlencode({
            "encryption": "none",
            "security": "reality",
            "sni": n["sni"],
            "fp": "chrome",
            "pbk": n["public_key"],
            "sid": n["short_id"],
            "type": "raw",
            "flow": n["flow"]
        })
        links.append(f"vless://{n['uuid']}@{host}:{port}?{q}#{name}")

    elif t == "shadowsocks":
        raw = n["method"] + ":" + n["password"]
        userinfo = base64.urlsafe_b64encode(raw.encode()).decode().rstrip("=")
        links.append(f"ss://{userinfo}@{host}:{port}#{name}")

    elif t == "vless-ws-tls":
        q = urllib.parse.urlencode({
            "encryption": "none",
            "security": "tls",
            "sni": n["sni"],
            "type": "ws",
            "path": n["path"],
            "host": n["sni"]
        })
        links.append(f"vless://{n['uuid']}@{host}:{port}?{q}#{name}")

    elif t == "vless-ws-cf-tunnel":
        # TLS 由 Cloudflare 边缘终止；Tunnel 将 WebSocket 转发到 VPS 本机 Xray。
        q = urllib.parse.urlencode({
            "encryption": "none",
            "security": "tls",
            "sni": n["sni"],
            "type": "ws",
            "path": n["path"],
            "host": n["sni"]
        })
        links.append(f"vless://{n['uuid']}@{host}:{port}?{q}#{name}")

with open(base + "/data/subscription.txt", "w") as f:
    f.write("\n".join(links) + ("\n" if links else ""))

encoded = base64.b64encode("\n".join(links).encode()).decode()
with open(base + "/data/subscription.b64", "w") as f:
    f.write(encoded + "\n")

os.chmod(base + "/data/subscription.txt", 0o600)
os.chmod(base + "/data/subscription.b64", 0o600)
print("订阅节点数量：", len(links))
if not links:
    raise SystemExit("错误：订阅中没有任何节点")
PY

    local node_count reality_count ss_count tls_count
    node_count="$(jq 'length' "$SUBJSON")"
    reality_count="$(jq '[.[] | select(.type == "vless-reality")] | length' "$SUBJSON")"
    ss_count="$(jq '[.[] | select(.type == "shadowsocks")] | length' "$SUBJSON")"
    tls_count="$(jq '[.[] | select(.type == "vless-ws-tls")] | length' "$SUBJSON")"
    cf_count="$(jq '[.[] | select(.type == "vless-ws-cf-tunnel")] | length' "$SUBJSON")"
    info "节点清单统计：总计=$node_count，REALITY=$reality_count，SS=$ss_count，TLS=$tls_count，CF Tunnel=$cf_count"
    if [[ "$reality_count" -eq 0 ]]; then
        warn "未生成 VLESS REALITY。请检查前面的 x25519 密钥生成/解析日志。"
    fi
    if [[ "${DOMAIN_OK:-0}" == 1 && "${TLS_OK:-0}" != 1 ]]; then
        warn "域名检查通过，但 TLS 节点未生成；请查看证书申请、80 端口及证书安装日志。"
    fi
}

# -------------------- 在线订阅 HTTP/HTTPS 服务 --------------------

install_subscription_server() {
    # 刷新订阅时也从已保存的配置中读取端口，避免 set -u 下变量未定义。
    if [[ -f "$SUB_PORT_FILE" ]]; then
        # shellcheck disable=SC1090
        source "$SUB_PORT_FILE"
    fi

    [[ "${SUB_PORT:-}" =~ ^[0-9]+$ ]] &&
        (( SUB_PORT >= 1 && SUB_PORT <= 65535 )) ||
        die "订阅端口未配置或无效，请先执行一键安装 / 自动修复。"

    [[ -f "$SUB_TOKEN_FILE" ]] ||
        openssl rand -hex 32 > "$SUB_TOKEN_FILE"
    chmod 600 "$SUB_TOKEN_FILE"

    local token
    token="$(tr -d '\r\n' < "$SUB_TOKEN_FILE")"
    [[ "$token" =~ ^[a-fA-F0-9]{64}$ ]] ||
        die "订阅 token 格式异常。"

    local tls_enabled=0
    if [[ "${TLS_OK:-0}" == 1 ]] &&
       [[ -s "$BASE/certs/fullchain.pem" ]] &&
       [[ -s "$BASE/certs/key.pem" ]]; then
        tls_enabled=1
    fi

    # 订阅服务单独运行，不依赖或覆盖现有 Nginx / 面板。
    cat > "$SUB_SERVER" <<'PY'
#!/usr/bin/env python3
import hmac
import os
import ssl
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

BASE = "/opt/xiazheteng-node"
DATA = BASE + "/data"
PORT = int(os.environ["SUB_PORT"])
TOKEN_FILE = DATA + "/subscription.token"
SUB_FILE = DATA + "/subscription.b64"
TLS_ENABLED = os.environ.get("SUB_TLS", "0") == "1"
CERT = BASE + "/certs/fullchain.pem"
KEY = BASE + "/certs/key.pem"

def read_token():
    with open(TOKEN_FILE, "r") as f:
        return f.read().strip()

class Handler(BaseHTTPRequestHandler):
    server_version = "SubscriptionService"
    sys_version = ""

    def log_message(self, fmt, *args):
        # 不在日志中记录 URL 查询参数，避免泄露 token。
        print("%s - %s" % (self.client_address[0], fmt.split("%")[0]))

    def do_GET(self):
        parsed = urlparse(self.path)
        if parsed.path != "/sub":
            self.send_error(404)
            return

        supplied = parse_qs(parsed.query).get("token", [""])[0]
        expected = read_token()
        if not hmac.compare_digest(supplied, expected):
            self.send_error(403, "Invalid subscription token")
            return

        try:
            with open(SUB_FILE, "rb") as f:
                body = f.read().strip() + b"\n"
        except OSError:
            self.send_error(503, "Subscription not ready")
            return

        self.send_response(200)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        self.wfile.write(body)

    def do_HEAD(self):
        # 不泄露订阅内容；真实检查使用带 token 的 GET 请求。
        self.send_error(405)

class Server(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

server = Server(("0.0.0.0", PORT), Handler)
if TLS_ENABLED:
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.minimum_version = ssl.TLSVersion.TLSv1_2
    ctx.load_cert_chain(CERT, KEY)
    server.socket = ctx.wrap_socket(server.socket, server_side=True)

server.serve_forever()
PY
    chmod 700 "$SUB_SERVER"

    cat > "$SUB_UNIT" <<EOF
# xiazheteng-node-manager
[Unit]
Description=Xia Zhe Teng Online Subscription Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=SUB_PORT=$SUB_PORT
Environment=SUB_TLS=$tls_enabled
ExecStart=/usr/bin/python3 $SUB_SERVER
WorkingDirectory=$BASE
Restart=on-failure
RestartSec=3
UMask=0077
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

    chmod 644 "$SUB_UNIT"
    systemctl daemon-reload
    systemctl enable "$SUB_SERVICE"
    systemctl restart "$SUB_SERVICE"

    sleep 1
    systemctl is-active --quiet "$SUB_SERVICE" ||
        die "在线订阅服务未能启动，请检查 journalctl -u $SUB_SERVICE。"

    SUB_SCHEME="http"
    if [[ "$tls_enabled" == 1 ]]; then
        SUB_SCHEME="https"
    fi

    if [[ "$SUB_SCHEME" == "https" && -n "${DOMAIN:-}" ]]; then
        SUB_HOST="$DOMAIN"
    else
        # 确保 PUBLIC_IP 已初始化，避免 set -u 导致脚本退出。
        PUBLIC_IP="${PUBLIC_IP:-}"

        # 如果前面没有获取公网 IPv4，则尝试自动检测。
        if [[ -z "$PUBLIC_IP" ]]; then
            PUBLIC_IP="$(curl -4fsS \
                --connect-timeout 3 \
                --max-time 8 \
                https://api.ipify.org 2>/dev/null || true)"
        fi

        # 检测失败时明确报错，不生成错误的订阅链接。
        if [[ -z "$PUBLIC_IP" ]]; then
            die "无法获取公网 IPv4，订阅链接生成失败。请检查网络或手动配置 PUBLIC_IP。"
        fi

        SUB_HOST="$PUBLIC_IP"
    fi

    # 若使用标准端口，则不显示端口号。
    if { [[ "$SUB_SCHEME" == "https" && "$SUB_PORT" == 443 ]] ||
         [[ "$SUB_SCHEME" == "http" && "$SUB_PORT" == 80 ]]; }; then
        SUB_URL="$SUB_SCHEME://$SUB_HOST/sub?token=$token"
    else
        SUB_URL="$SUB_SCHEME://$SUB_HOST:$SUB_PORT/sub?token=$token"
    fi

    printf '%s\n' "$SUB_URL" > "$SUB_URL_FILE"
    chmod 600 "$SUB_URL_FILE"

    # 本机请求验证服务响应和 token 鉴权。
    local local_url
    local_url="$SUB_SCHEME://127.0.0.1:$SUB_PORT/sub?token=$token"

    if [[ "$SUB_SCHEME" == "https" ]]; then
        curl -kfsS --connect-timeout 3 --max-time 8 \
            "$local_url" -o "$DATA/subscription-check.tmp" ||
            die "在线 HTTPS 订阅接口本机验证失败。"
    else
        curl -fsS --connect-timeout 3 --max-time 8 \
            "$local_url" -o "$DATA/subscription-check.tmp" ||
            die "在线 HTTP 订阅接口本机验证失败。"
    fi

    [[ -s "$DATA/subscription-check.tmp" ]] ||
        die "订阅接口返回内容为空。"

    rm -f "$DATA/subscription-check.tmp"
    info "在线订阅服务启动并通过本机 HTTP 检查。"
}

show_subscription_url() {
    if [[ -s "$SUB_URL_FILE" ]]; then
        echo
        echo "============== 在线订阅链接 =============="
        cat "$SUB_URL_FILE"
        echo
        echo "订阅服务：$(systemctl is-active "$SUB_SERVICE" 2>/dev/null || true)"
        echo "订阅端口：${SUB_PORT:-未知}"
        echo "本机接口检查：通过"
        echo "=========================================="
        echo "注意：本机检查不等于外网可达性检查。"
        echo "请确认 VPS 安全组及防火墙已放行订阅端口。"
        echo
    fi
}

# -------------------- systemd Xray 服务 --------------------

install_service() {
    if [[ -e "$UNIT" ]] &&
       ! grep -q "xiazheteng-node-manager" "$UNIT"; then
        die "服务文件已存在且不属于本脚本：$UNIT"
    fi

    cat > "$UNIT" <<EOF
# xiazheteng-node-manager
[Unit]
Description=Xia Zhe Teng Independent Xray Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=$BIN run -config $CONF
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

    chmod 644 "$UNIT"
    systemctl daemon-reload

    "$BIN" run -test -config "$CONF" ||
        die "Xray 配置校验失败，拒绝启动。"

    systemctl enable "$SERVICE"
    systemctl restart "$SERVICE"
    sleep 2

    systemctl is-active --quiet "$SERVICE" ||
        die "Xray 服务未能启动，请检查 journalctl -u $SERVICE。"

    info "独立 Xray 服务启动成功。"
}

# -------------------- 防火墙检测 --------------------

report_firewall() {
    local p
    for p in "$@"; do
        if command -v ufw >/dev/null 2>&1 &&
           ufw status 2>/dev/null | grep -qi active; then
            warn "检测到 UFW 已启用。请确认 TCP/UDP $p 已放行；脚本不会重置防火墙。"
        fi
    done

    if command -v firewall-cmd >/dev/null 2>&1 &&
       firewall-cmd --state >/dev/null 2>&1; then
        warn "检测到 firewalld。请确认相应端口已放行；脚本不会重置防火墙。"
    fi

    warn "VPS 服务商安全组不一定可自动检测，请确认公网端口已放行。"
}

# -------------------- 安装主流程 --------------------

do_install() {
    detect_os
    install_dependencies
    detect_public_ipv4
    inspect_existing_services

    mkdir -p "$BASE" "$DATA" "$BASE/bin"
    chmod 700 "$BASE" "$DATA"

    if [[ -f "$ENVFILE" ]]; then
        # shellcheck disable=SC1090
        source "$ENVFILE"
        info "读取已有安装配置。"
    else
        read -r -p "请输入已经解析到本 VPS 的域名（没有域名直接回车）：" DOMAIN
        DOMAIN="${DOMAIN,,}"
        DOMAIN="${DOMAIN%.}"
        printf 'DOMAIN=%q\n' "$DOMAIN" > "$ENVFILE"
        chmod 600 "$ENVFILE"
    fi

    DOMAIN="${DOMAIN:-}"
    check_domain
    install_xray

    obtain_tls_certificate

    # 先分配订阅端口，避免 Xray 占用相同端口。
    setup_subscription_port

    export BASE
    # 清理上次安装留下的可选节点标记，避免 TLS 本轮失败却显示旧端口。
    rm -f "$DATA/tls.port" "$DATA/reality.port" "$DATA/shadowsocks.port"
    generate_configuration
    generate_subscription
    install_service

    # Xray 启动后再启动在线订阅服务。
    install_subscription_server

    # 安装后最终校验：配置有效、服务运行、订阅内容非空。
    "$BIN" run -test -config "$CONF" >/dev/null || die "安装后检查失败：Xray 配置验证未通过。"
    systemctl is-active --quiet "$SERVICE" || die "安装后检查失败：Xray 服务未运行。"
    [[ -s "$SUBFILE" ]] || die "安装后检查失败：订阅文件为空。"
    info "安装后检查通过：Xray 配置有效、服务运行中、订阅文件非空。"

    local ports=()
    [[ -f "$DATA/reality.port" ]] && ports+=("$(cat "$DATA/reality.port")")
    [[ -f "$DATA/shadowsocks.port" ]] && ports+=("$(cat "$DATA/shadowsocks.port")")
    [[ -f "$DATA/tls.port" ]] && ports+=("$(cat "$DATA/tls.port")")
    [[ -n "${SUB_PORT:-}" ]] && ports+=("$SUB_PORT")

    report_firewall "${ports[@]}"

    echo
    echo "================ 安装结果 ================"
    systemctl --no-pager --full status "$SERVICE" || true
    echo
    show_subscription_url
    echo "节点文件：$SUBFILE"
    echo "日志文件：$LOG"
    echo "==========================================="
}

# -------------------- Cloudflare Tunnel 独立节点 --------------------

install_cloudflared() {
    if [[ -x "$CLOUDFLARED_BIN" ]] && "$CLOUDFLARED_BIN" --version >/dev/null 2>&1; then
        info "检测到 cloudflared：$($CLOUDFLARED_BIN --version 2>/dev/null | head -n 1)"
        return 0
    fi

    local asset tmp
    case "$(uname -m)" in
        x86_64|amd64) asset="cloudflared-linux-amd64" ;;
        aarch64|arm64) asset="cloudflared-linux-arm64" ;;
        *) die "当前 CPU 架构不支持自动安装 cloudflared：$(uname -m)" ;;
    esac
    tmp="$(mktemp)"
    info "正在下载 cloudflared。"
    if ! curl -fL --retry 3 --connect-timeout 10 --max-time 180 \
        "https://github.com/cloudflare/cloudflared/releases/latest/download/$asset" -o "$tmp"; then
        rm -f "$tmp"
        die "cloudflared 下载失败。"
    fi
    install -m 0755 "$tmp" "$CLOUDFLARED_BIN"
    rm -f "$tmp"
    "$CLOUDFLARED_BIN" --version >/dev/null 2>&1 || die "cloudflared 安装后无法执行。"
    info "cloudflared 安装完成。"
}

cf_tunnel_status() {
    echo
    echo "============== CF Tunnel 状态 =============="
    echo "Xray 服务：$(systemctl is-active "$CF_SERVICE" 2>/dev/null || true)"
    echo "Tunnel 服务：$(systemctl is-active "$CF_TUNNEL_SERVICE" 2>/dev/null || true)"
    if [[ -f "$CF_SETTINGS" ]]; then
        # shellcheck disable=SC1090
        source "$CF_SETTINGS"
        echo "域名：${CF_DOMAIN:-未知}"
        echo "本机 WebSocket 端口：${CF_PORT:-未知}"
        echo "WebSocket 路径：${CF_PATH:-未知}"
    else
        echo "尚未配置 CF Tunnel 节点。"
    fi
    echo "============================================"
    echo "提示：Tunnel 的 Public Hostname 需在 Cloudflare Zero Trust 控制台配置。"
    echo "============================================"
}

cf_tunnel_deploy() {
    need_root
    detect_os
    install_dependencies
    mkdir -p "$BASE" "$DATA" "$BASE/bin"
    chmod 700 "$BASE" "$DATA" "$BASE/bin"
    install_xray
    install_cloudflared

    local cf_domain cf_token cf_path cf_port cf_uuid input_domain input_path
    if [[ -f "$CF_SETTINGS" ]]; then
        # shellcheck disable=SC1090
        source "$CF_SETTINGS"
        cf_domain="${CF_DOMAIN:-}"
        cf_path="${CF_PATH:-/cfws}"
        cf_port="${CF_PORT:-}"
        cf_uuid="${CF_UUID:-}"
        echo "检测到已有 CF Tunnel 节点配置。"
        read -r -p "要复用域名 [$cf_domain]？直接回车复用，或输入新域名：" input_domain
        cf_domain="${input_domain:-$cf_domain}"
        read -r -p "WebSocket 路径 [$cf_path]：" input_path
        cf_path="${input_path:-$cf_path}"
    else
        read -r -p "请输入 Cloudflare Tunnel 的公开域名（例如 cf.example.com）：" cf_domain
        read -r -p "WebSocket 路径 [/cfws]：" cf_path
        cf_path="${cf_path:-/cfws}"
        cf_port=""
        cf_uuid=""
    fi

    cf_domain="${cf_domain,,}"
    cf_domain="${cf_domain%.}"
    [[ "$cf_domain" =~ ^[a-zA-Z0-9.-]+$ && "$cf_domain" != *..* && "$cf_domain" != .* && "$cf_domain" != *. ]] || die "域名格式不合法。"
    [[ "$cf_path" == /* && "$cf_path" != *' '* && "$cf_path" != *'?'* && "$cf_path" != *'#'* ]] || die "WebSocket 路径必须以 / 开头，且不能包含空格、? 或 #。"

    read -r -s -p "请输入 Cloudflare Tunnel Token（输入内容不会显示）：" cf_token
    echo
    [[ -n "$cf_token" && "$cf_token" != *$'\n'* && "$cf_token" != *$'\r'* ]] || die "Tunnel Token 不能为空或包含换行。"

    if [[ ! "$cf_port" =~ ^[0-9]+$ ]] || (( cf_port < 1 || cf_port > 65535 )); then
        cf_port="$(choose_random_port)" || die "无法为 CF Xray 选择本机端口。"
    fi
    if [[ -z "$cf_uuid" ]]; then
        cf_uuid="$(cat /proc/sys/kernel/random/uuid)"
    fi

    # 独立的 Xray 配置只监听回环地址，不占用公网端口，也不改写主 Xray 配置。
    export CF_DOMAIN="$cf_domain" CF_PORT="$cf_port" CF_UUID="$cf_uuid" CF_PATH="$cf_path"
    python3 - <<'PY'
import json, os
base = "/opt/xiazheteng-node"
config = {
    "log": {"loglevel": "warning"},
    "inbounds": [{
        "tag": "in-cf-tunnel-ws",
        "listen": "127.0.0.1",
        "port": int(os.environ["CF_PORT"]),
        "protocol": "vless",
        "settings": {"clients": [{"id": os.environ["CF_UUID"]}], "decryption": "none"},
        "streamSettings": {
            "network": "ws",
            "security": "none",
            "wsSettings": {"path": os.environ["CF_PATH"]}
        }
    }],
    "outbounds": [{"protocol": "freedom", "tag": "direct"}]
}
path = base + "/cf-tunnel-xray.json"
tmp = path + ".tmp"
with open(tmp, "w") as f:
    json.dump(config, f, indent=2)
os.chmod(tmp, 0o600)
os.replace(tmp, path)
PY

    # Token 单独保存，文件仅 root 可读。
    printf 'CF_DOMAIN=%q\nCF_PORT=%q\nCF_UUID=%q\nCF_PATH=%q\n' \
        "$cf_domain" "$cf_port" "$cf_uuid" "$cf_path" > "$CF_SETTINGS"
    printf 'TUNNEL_TOKEN=%s\n' "$cf_token" > "$CF_TOKEN_FILE"
    chmod 600 "$CF_SETTINGS" "$CF_TOKEN_FILE"
    unset cf_token

    cat > "$CF_UNIT" <<EOF
# xiazheteng-node-manager
[Unit]
Description=Xia Zhe Teng Cloudflare Tunnel VLESS WebSocket Inbound
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=$BIN run -config $CF_CONF
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
    chmod 644 "$CF_UNIT"

    cat > "$CF_TUNNEL_UNIT" <<EOF
# xiazheteng-node-manager
[Unit]
Description=Xia Zhe Teng Cloudflare Tunnel
After=network-online.target $CF_SERVICE.service
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=$CF_TOKEN_FILE
ExecStart=$CLOUDFLARED_BIN tunnel --no-autoupdate run --token \${TUNNEL_TOKEN}
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
    chmod 644 "$CF_TUNNEL_UNIT"

    "$BIN" run -test -config "$CF_CONF" || die "CF Tunnel 专用 Xray 配置校验失败。"

    # 将 CF 节点合并进统一清单；重复执行时替换旧 CF 节点，避免重复追加。
    python3 - <<'PY'
import json, os
base = "/opt/xiazheteng-node/data"
path = base + "/nodes.json"
try:
    with open(path) as f:
        nodes = json.load(f)
    if not isinstance(nodes, list):
        nodes = []
except (OSError, json.JSONDecodeError):
    nodes = []
nodes = [n for n in nodes if not (isinstance(n, dict) and n.get("type") == "vless-ws-cf-tunnel")]
nodes.append({
    "type": "vless-ws-cf-tunnel",
    "address": os.environ["CF_DOMAIN"],
    "port": 443,
    "uuid": os.environ["CF_UUID"],
    "path": os.environ["CF_PATH"],
    "sni": os.environ["CF_DOMAIN"]
})
tmp = path + ".tmp"
with open(tmp, "w") as f:
    json.dump(nodes, f, indent=2)
os.chmod(tmp, 0o600)
os.replace(tmp, path)
PY

    systemctl daemon-reload
    systemctl enable "$CF_SERVICE" "$CF_TUNNEL_SERVICE"
    systemctl restart "$CF_SERVICE"
    sleep 1
    systemctl is-active --quiet "$CF_SERVICE" || die "CF 专用 Xray 服务启动失败，请查看 journalctl -u $CF_SERVICE。"
    systemctl restart "$CF_TUNNEL_SERVICE"
    sleep 2
    systemctl is-active --quiet "$CF_TUNNEL_SERVICE" || warn "cloudflared 服务未处于 active 状态；请检查 Token 和 journalctl -u $CF_TUNNEL_SERVICE。"

    info "CF Tunnel 节点配置已写入统一节点清单。"
    echo
    echo "================ CF Tunnel 配置结果 ================"
    echo "域名：$cf_domain"
    echo "本机 WebSocket 目标：http://127.0.0.1:$cf_port"
    echo "WebSocket 路径：$cf_path"
    echo "VLESS UUID：$cf_uuid"
    echo
    echo "请在 Cloudflare Zero Trust 控制台的该 Tunnel 中添加 Public Hostname："
    echo "Hostname：$cf_domain"
    echo "Service Type：HTTP"
    echo "Service URL：http://127.0.0.1:$cf_port"
    echo "====================================================="
    echo "完成后选择菜单 [3] 整合订阅 / 刷新订阅。"
}

cf_tunnel_menu() {
    while true; do
        echo
        echo "========== Cloudflare Tunnel 管理 =========="
        echo "[1] 部署 / 更新 CF Tunnel 节点"
        echo "[2] 查看 CF Tunnel 服务状态"
        echo "[3] 重启 CF Tunnel 服务"
        echo "[0] 返回主菜单"
        read -r -p "请选择：" cf_choice
        case "$cf_choice" in
            1) cf_tunnel_deploy ;;
            2) cf_tunnel_status ;;
            3)
                systemctl restart "$CF_SERVICE" "$CF_TUNNEL_SERVICE"
                sleep 1
                cf_tunnel_status
                ;;
            0) return 0 ;;
            *) echo "无效选项。" ;;
        esac
    done
}

# -------------------- 安全卸载 --------------------

do_uninstall() {
    echo "开始移除本脚本创建的独立服务和文件。"

    if [[ -f "$CF_TUNNEL_UNIT" ]] && grep -q "xiazheteng-node-manager" "$CF_TUNNEL_UNIT"; then
        systemctl disable --now "$CF_TUNNEL_SERVICE" 2>/dev/null || true
        rm -f "$CF_TUNNEL_UNIT"
        systemctl daemon-reload
    fi
    if [[ -f "$CF_UNIT" ]] && grep -q "xiazheteng-node-manager" "$CF_UNIT"; then
        systemctl disable --now "$CF_SERVICE" 2>/dev/null || true
        rm -f "$CF_UNIT"
        systemctl daemon-reload
    fi

    if [[ -f "$SUB_UNIT" ]] &&
       grep -q "xiazheteng-node-manager" "$SUB_UNIT"; then
        systemctl disable --now "$SUB_SERVICE" 2>/dev/null || true
        rm -f "$SUB_UNIT"
        systemctl daemon-reload
    else
        warn "在线订阅服务文件不存在或不属于本脚本，不做处理。"
    fi

    if [[ -f "$UNIT" ]] &&
       grep -q "xiazheteng-node-manager" "$UNIT"; then
        systemctl disable --now "$SERVICE" 2>/dev/null || true
        rm -f "$UNIT"
        systemctl daemon-reload
    else
        warn "Xray 服务文件不存在或不属于本脚本，不做处理。"
    fi

    if [[ -L "$SHORTCUT" ]] ||
       { [[ -f "$SHORTCUT" ]] &&
         grep -q "xiazheteng-node-manager" "$SHORTCUT" 2>/dev/null; }; then
        rm -f "$SHORTCUT"
    fi

    if [[ "$BASE" == "/opt/xiazheteng-node" &&
          -d "$BASE" &&
          -f "$ENVFILE" ]]; then
        rm -rf -- "$BASE"
    fi

    warn "系统依赖、acme.sh、已有服务和防火墙规则不会自动删除。"
    info "卸载操作完成。"
}

# -------------------- 快捷命令 --------------------

create_shortcut() {
    local self
    self="$(readlink -f "$0")"
    [[ -f "$self" ]] || die "无法定位当前脚本文件。"

    install -m 0755 "$self" "$BASE/manager.sh"

    cat > "$SHORTCUT" <<'EOF'
#!/usr/bin/env bash
# xiazheteng-node-manager
exec bash /opt/xiazheteng-node/manager.sh "$@"
EOF
    chmod 755 "$SHORTCUT"
    info "快捷命令创建完成。输入 x 即可启动管理菜单。"
}

# -------------------- 菜单 --------------------

menu() {
    while true; do
        echo
        echo "=========================================="
        echo "       VPS 节点一键部署管理系统"
        echo "=========================================="
        echo "[1] 一键安装 / 自动修复"
        echo "[2] 卸载脚本管理的组件"
        echo "[3] 整合订阅 / 刷新订阅"
        echo "[4] 创建快捷命令 x"
        echo "[5] 显示在线订阅链接"
        echo "[6] 独立部署 / 管理 Cloudflare Tunnel 节点"
        echo "[0] 退出"
        echo "=========================================="
        read -r -p "请选择：" choice

        case "$choice" in
            1) do_install ;;
            2) do_uninstall ;;
            3)
                if [[ -x "$BIN" && -f "$CONF" ]]; then
                    generate_subscription
                    if systemctl is-active --quiet "$SERVICE"; then
                        install_subscription_server
                        show_subscription_url
                    else
                        warn "Xray 服务未运行，请先选择安装 / 修复。"
                    fi
                else
                    warn "尚未安装本脚本的节点。"
                fi
                ;;
            4) create_shortcut ;;
            5) show_subscription_url ;;
            6) cf_tunnel_menu ;;
            0) echo "已退出。"; exit 0 ;;
            *) echo "无效选项。" ;;
        esac
    done
}

main() {
    need_root
    detect_os

    if [[ ! -f "$ENVFILE" ]]; then
        mkdir -p "$BASE"
        echo "首次初始化："
        read -r -p "请输入已解析到本 VPS 的域名（无域名直接回车）：" DOMAIN
        DOMAIN="${DOMAIN,,}"
        DOMAIN="${DOMAIN%.}"
        printf 'DOMAIN=%q\n' "$DOMAIN" > "$ENVFILE"
        chmod 600 "$ENVFILE"
    fi

    # shellcheck disable=SC1090
    source "$ENVFILE"
    menu
}

main "$@"