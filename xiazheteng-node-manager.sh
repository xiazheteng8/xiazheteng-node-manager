
#!/usr/bin/env bash
# ============================================================
# 瞎折腾吧 VPS 节点自动部署管理器
# 独立 Xray 实例 | 环境检测 | 端口避让 | 订阅生成 | 安全卸载
# 支持：Debian / Ubuntu，systemd，x86_64 / ARM64
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
SUBFILE="$DATA/subscription.txt"
SUBJSON="$DATA/nodes.json"
SUBURLFILE="$DATA/subscription-url.txt"
PORTFILE="$DATA/ports.env"
SHORTCUT="/usr/local/bin/x"
XRAY_REPO="XTLS/Xray-core"

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
        warn "无法获取公网 IPv4；将尝试从本地路由获取地址。"
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
        warn "$DOMAIN 没有 IPv4 解析，域名模式的 TLS 节点将跳过。"
        return 0
    fi

    if ! grep -Fxq "$PUBLIC_IP" <<< "$ips"; then
        warn "$DOMAIN 的 A 记录不包含本机公网 IPv4，跳过 TLS 节点。"
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

    if command -v ss >/dev/null 2>&1; then
        ss -lntp 2>/dev/null | tee -a "$LOG" >/dev/null || true
    fi
}

# -------------------- 安装独立 Xray --------------------

install_xray() {
    # 已有本脚本管理的二进制且可运行，则不重复下载。
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

    # 先在临时位置验证，不覆盖系统已有的 /usr/local/bin/xray。
    install -m 0755 "$tmp/unpack/xray" "$tmp/xray-test"
    "$tmp/xray-test" version >/dev/null ||
        die "下载的 Xray 无法执行。"

    install -m 0755 "$tmp/unpack/xray" "$BIN"
    rm -rf "$tmp"
    info "Xray 安装完成：$("$BIN" version | head -n 1)"
}

# -------------------- REALITY 密钥 --------------------

generate_reality_keys() {
    local output
    output="$("$BIN" x25519 2>&1)" ||
        die "Xray 无法生成 REALITY 密钥。"

    PRIVATE_KEY="$(sed -nE 's/^(PrivateKey|Private key):[[:space:]]*//p' <<< "$output" | head -n 1)"
    PUBLIC_KEY="$(sed -nE 's/^(Password|PublicKey|Public key):[[:space:]]*//p' <<< "$output" | head -n 1)"

    # 新旧版本输出格式存在差异，失败时不生成伪造节点。
    if [[ -z "$PRIVATE_KEY" || -z "$PUBLIC_KEY" ]]; then
        warn "当前 Xray 的密钥输出格式无法自动识别。"
        warn "REALITY 节点将跳过，不会写入无效参数。"
        PRIVATE_KEY=""
        PUBLIC_KEY=""
        return 0
    fi
}

# -------------------- 可选 TLS 证书 --------------------

obtain_tls_certificate() {
    TLS_OK=0
    [[ "${DOMAIN_OK:-0}" == 1 ]] || return 0

    # standalone ACME 需要占用 TCP 80；绝不抢占已有服务的端口。
    if port_in_use 80; then
        warn "TCP 80 已被占用；为保护现有服务，跳过自动 TLS 证书申请。"
        return 0
    fi

    local email
    email="admin@$DOMAIN"

    if ! command -v socat >/dev/null 2>&1; then
        apt-get install -y socat >/dev/null || {
            warn "无法安装 socat，跳过 TLS。"
            return 0
        }
    fi

    if [[ ! -x "$HOME/.acme.sh/acme.sh" ]]; then
        curl -fsSL --retry 2 --max-time 60 \
            https://get.acme.sh -o "$BASE/acme-install.sh" || {
            warn "无法下载 acme.sh，跳过 TLS。"
            return 0
        }

        if ! sh "$BASE/acme-install.sh" email="$email"; then
            warn "acme.sh 安装失败，跳过 TLS。"
            return 0
        fi
    fi

    local acme="$HOME/.acme.sh/acme.sh"
    [[ -x "$acme" ]] || {
        warn "找不到 acme.sh，跳过 TLS。"
        return 0
    }

    if ! "$acme" --issue --standalone -d "$DOMAIN" \
        --server letsencrypt --keylength ec-256 --force; then
        warn "证书签发失败；保留其他节点，跳过 TLS 节点。"
        return 0
    fi

    mkdir -p "$BASE/certs"
    chmod 700 "$BASE/certs"

    if ! "$acme" --install-cert -d "$DOMAIN" --ecc \
        --key-file "$BASE/certs/key.pem" \
        --fullchain-file "$BASE/certs/fullchain.pem" \
        --reloadcmd "systemctl restart $SERVICE 2>/dev/null || true"; then
        warn "证书安装失败，跳过 TLS 节点。"
        return 0
    fi

    chmod 600 "$BASE/certs/"*.pem
    TLS_OK=1
    info "TLS 证书安装完成。"
}

# -------------------- 配置生成 --------------------

generate_configuration() {
    local reality_port ss_port tls_port
    local uuid ss_password short_id
    local -a ports

    reality_port="$(choose_port 443 8443 2053 2083 2087 2096 2443 10443 \
        || choose_random_port)" || die "无法为 REALITY 选择端口。"

    ss_port="$(choose_port 8388 8389 8390 18443 18444 \
        || choose_random_port)" || die "无法为 Shadowsocks 选择端口。"

    tls_port=""
    if [[ "${TLS_OK:-0}" == 1 ]]; then
        tls_port="$(choose_port 10443 1443 2443 3443 4443 \
            || choose_random_port)" || {
            warn "无可用 TLS 端口，跳过 TLS 节点。"
            TLS_OK=0
        }
    fi

    uuid="$(cat /proc/sys/kernel/random/uuid)"
    ss_password="$(openssl rand -base64 24 | tr -d '\n')"
    short_id="$(openssl rand -hex 8)"

    generate_reality_keys

    export REALITY_PORT="$reality_port"
    export SS_PORT="$ss_port"
    export TLS_PORT="${tls_port:-0}"
    export NODE_UUID="$uuid"
    export SS_PASSWORD="$ss_password"
    export SHORT_ID="$short_id"
    export PRIVATE_KEY="${PRIVATE_KEY:-}"
    export PUBLIC_KEY="${PUBLIC_KEY:-}"
    export DOMAIN="${DOMAIN:-}"
    export PUBLIC_IP

    mkdir -p "$DATA"
    python3 - <<'PY'
import json, os

base = os.environ["BASE"] if "BASE" in os.environ else "/opt/xiazheteng-node"
domain = os.environ.get("DOMAIN", "")
ip = os.environ["PUBLIC_IP"]
uuid = os.environ["NODE_UUID"]
short_id = os.environ["SHORT_ID"]
private_key = os.environ.get("PRIVATE_KEY", "")
reality_port = int(os.environ["REALITY_PORT"])
ss_port = int(os.environ["SS_PORT"])
tls_port = int(os.environ["TLS_PORT"])
ss_password = os.environ["SS_PASSWORD"]

inbounds = []

# REALITY: 不创建不完整的密钥配置。
if private_key:
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
        },
        "sniffing": {
            "enabled": True,
            "destOverride": ["http", "tls", "quic"]
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

# TLS 只有证书已安装并验证后才启用。
if tls_port and domain and os.path.isfile(base + "/certs/fullchain.pem") \
        and os.path.isfile(base + "/certs/key.pem"):
    inbounds.append({
        "tag": "in-vless-ws-tls",
        "listen": "0.0.0.0",
        "port": tls_port,
        "protocol": "vless",
        "settings": {
            "clients": [{"id": uuid}],
            "decryption": "none"
        },
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

nodes = []
if private_key:
    nodes.append({
        "type": "vless-reality",
        "address": ip,
        "port": reality_port,
        "uuid": uuid,
        "flow": "xtls-rprx-vision",
        "security": "reality",
        "public_key": os.environ.get("PUBLIC_KEY", ""),
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

    # 导出变量供 Python heredoc 使用。
    # 此函数的调用方必须先 export BASE。
    echo "$reality_port" > "$DATA/reality.port"
    echo "$ss_port" > "$DATA/shadowsocks.port"
    [[ -n "$tls_port" ]] && echo "$tls_port" > "$DATA/tls.port" || true
}

# -------------------- 订阅生成 --------------------

generate_subscription() {
    [[ -f "$SUBJSON" ]] || {
        warn "没有节点清单；请先执行安装。"
        return 1
    }

    # 仅从当前配置中验证真实存在的入站。
    "$BIN" run -test -config "$CONF" >/dev/null 2>&1 || {
        warn "配置验证失败，不生成订阅。"
        return 1
    }

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
        links.append(
            f"vless://{n['uuid']}@{host}:{port}?{q}#{name}"
        )

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

with open(base + "/data/subscription.txt", "w") as f:
    f.write("\n".join(links) + ("\n" if links else ""))

encoded = base64.b64encode("\n".join(links).encode()).decode()
with open(base + "/data/subscription.b64", "w") as f:
    f.write(encoded + "\n")

os.chmod(base + "/data/subscription.txt", 0o600)
os.chmod(base + "/data/subscription.b64", 0o600)
print("订阅节点数量：", len(links))
PY

    # 订阅通过本机验证不代表已完成外部连通性测试。
    info "订阅文件：$SUBFILE"
    info "Base64 订阅：$DATA/subscription.b64"
}

# -------------------- systemd 服务 --------------------

install_service() {
    # 不接管或替换其他软件的服务文件。
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

    # 先验证配置再启动，失败时不重启原有服务。
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
        # 配置文件仅由本脚本生成，权限为 600。
        # shellcheck disable=SC1090
        source "$ENVFILE"
        info "读取已有安装配置。"
    else
        echo
        read -r -p "请输入已经解析到本 VPS 的域名（没有域名直接回车）：" DOMAIN
        DOMAIN="${DOMAIN,,}"
        DOMAIN="${DOMAIN%.}"
        printf 'DOMAIN=%q\n' "$DOMAIN" > "$ENVFILE"
        chmod 600 "$ENVFILE"
    fi

    DOMAIN="${DOMAIN:-}"
    check_domain
    install_xray

    # 证书申请可能失败，不阻断其他节点安装。
    obtain_tls_certificate

    export BASE
    generate_configuration
    generate_subscription
    install_service

    local ports=()
    [[ -f "$DATA/reality.port" ]] && ports+=("$(cat "$DATA/reality.port")")
    [[ -f "$DATA/shadowsocks.port" ]] && ports+=("$(cat "$DATA/shadowsocks.port")")
    [[ -f "$DATA/tls.port" ]] && ports+=("$(cat "$DATA/tls.port")")

    report_firewall "${ports[@]}"

    echo
    echo "================ 安装结果 ================"
    systemctl --no-pager --full status "$SERVICE" || true
    echo
    echo "节点订阅文件：$SUBFILE"
    echo "Base64 订阅文件：$DATA/subscription.b64"
    echo "日志文件：$LOG"
    echo "==========================================="
}

# -------------------- 安全卸载 --------------------

do_uninstall() {
    echo "开始移除本脚本创建的独立服务和文件。"

    if [[ -f "$UNIT" ]] &&
       grep -q "xiazheteng-node-manager" "$UNIT"; then
        systemctl disable --now "$SERVICE" 2>/dev/null || true
        rm -f "$UNIT"
        systemctl daemon-reload
    else
        warn "服务文件不存在或不属于本脚本，不做处理。"
    fi

    if [[ -L "$SHORTCUT" ]] ||
       { [[ -f "$SHORTCUT" ]] &&
         grep -q "xiazheteng-node-manager" "$SHORTCUT" 2>/dev/null; }; then
        rm -f "$SHORTCUT"
    fi

    # 仅删除独立目录；不删除系统 Xray、面板、Nginx 或其他服务。
    if [[ "$BASE" == "/opt/xiazheteng-node" &&
          -d "$BASE" &&
          -f "$ENVFILE" ]]; then
        rm -rf -- "$BASE"
    fi

    warn "如果此前由本脚本安装了 acme.sh 或系统依赖，它们不会自动删除。"
    warn "现有防火墙规则及服务商安全组规则不会自动清理。"
    info "卸载操作完成。"
}

# -------------------- 快捷命令 --------------------

create_shortcut() {
    local self
    self="$(readlink -f "$0")"
    [[ -f "$self" ]] || die "无法定位当前脚本文件。"

    # 将脚本安装到固定位置，避免用户移动原文件后快捷命令失效。
    install -m 0755 "$self" "$BASE/manager.sh"

    cat > "$SHORTCUT" <<'EOF'
#!/usr/bin/env bash
# xiazheteng-node-manager
exec bash /opt/xiazheteng-node/manager.sh "$@"
EOF
    chmod 755 "$SHORTCUT"

    info "快捷命令创建完成。以后输入 x 即可启动管理菜单。"
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
        echo "[0] 退出"
        echo "=========================================="
        read -r -p "请选择：" choice

        case "$choice" in
            1) do_install ;;
            2) do_uninstall ;;
            3)
                if [[ -x "$BIN" && -f "$CONF" ]]; then
                    generate_subscription
                else
                    warn "尚未安装本脚本的节点。"
                fi
                ;;
            4) create_shortcut ;;
            0) echo "已退出。"; exit 0 ;;
            *) echo "无效选项。" ;;
        esac
    done
}

main() {
    need_root
    detect_os

    # 首次初始化询问域名；之后读取配置，不重复询问。
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
