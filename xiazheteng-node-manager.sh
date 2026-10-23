#!/usr/bin/env bash
# 3x-ui 一键部署 + 多协议节点生成 + 订阅链接
# 用法(GitHub 一键): bash <(curl -fsSL https://raw.githubusercontent.com/<用户名>/<仓库>/main/install.sh)
# 可提前用环境变量注入, 跳过交互: DOMAIN XUI_USER XUI_PASS XUI_PORT REALITY_SNI
# 开始时只问一次, 之后全程无交互。

set -uo pipefail

OUT_DIR=/root/xui-deploy
LOG=$OUT_DIR/deploy.log
mkdir -p "$OUT_DIR"
exec > >(tee -a "$LOG") 2>&1

log()  { echo -e "\n[$(date +%T)] \033[32m== $*\033[0m"; }
warn() { echo -e "[$(date +%T)] \033[33mWARN: $*\033[0m"; }
die()  { echo -e "[$(date +%T)] \033[31mERROR: $*\033[0m"; exit 1; }

[ "$(id -u)" -eq 0 ] || die "请使用 root 运行"

rand_str() { tr -dc 'a-z0-9' </dev/urandom | head -c "$1"; }
rand_mix() { tr -dc 'A-Za-z0-9' </dev/urandom | head -c "$1"; }

# 端口是否空闲
port_free() { ! ss -lntu 2>/dev/null | awk '{print $5}' | grep -qE "[:.]$1\$"; }

# 已占用端口(本次脚本分配过的)
USED=" "
RET=""
take_port() { # take_port <想要的端口, 可为空>
  local want=$1 p
  if [ -n "$want" ] && [[ "$USED" != *" $want "* ]] && port_free "$want"; then
    p=$want
  else
    while :; do
      p=$(shuf -i 20000-60000 -n1)
      [[ "$USED" != *" $p "* ]] && port_free "$p" && break
    done
  fi
  USED+=" $p "
  RET=$p
}

# ---------- 1. 开始前一次性输入 ----------
log "配置输入(回车使用默认值; 全部可用环境变量预先注入)"
ask() { # ask VAR "提示" 默认值
  local var=$1 prompt=$2 def=${3:-} val=""
  [ -n "${!var:-}" ] && return
  if [ -r /dev/tty ]; then read -r -p "$prompt [${def:-留空}]: " val </dev/tty || true; fi
  printf -v "$var" '%s' "${val:-$def}"
}
ask DOMAIN       "域名(解析到本机IP, 用于 TLS 节点, 没有就留空)" ""
ask XUI_USER     "3x-ui 管理账号" "admin$(rand_str 4)"
ask XUI_PASS     "3x-ui 管理密码" "$(rand_mix 14)"
ask XUI_PORT     "3x-ui 面板端口" ""
ask REALITY_SNI  "Reality 伪装域名" "www.microsoft.com"
[ -z "$XUI_PORT" ] && XUI_PORT=$(shuf -i 20000-60000 -n1)
BASE="/$(rand_str 10)/"
SUBID=$(rand_str 16)
SUB_PATH="/$(rand_str 12)/"
[ -n "${DOMAIN}" ] && DOMAIN=$(echo "$DOMAIN" | tr 'A-Z' 'a-z' | sed 's#^https\?://##; s#/.*##')

# ---------- 2. 系统识别与依赖 ----------
log "识别系统并安装依赖"
if command -v apt-get >/dev/null 2>&1; then
  PM=deb
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y -qq >/dev/null 2>&1
  apt-get install -y -qq curl wget jq tar unzip openssl socat cron iproute2 sqlite3 ca-certificates >/dev/null 2>&1
elif command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then
  PM=rhel
  P=$(command -v dnf || command -v yum)
  $P install -y -q curl wget jq tar unzip openssl socat cronie iproute sqlite ca-certificates >/dev/null 2>&1
else
  die "不支持的系统(仅支持 Debian/Ubuntu/CentOS/RHEL 系)"
fi
for c in curl jq tar openssl ss sqlite3; do command -v "$c" >/dev/null 2>&1 || die "缺少依赖: $c"; done

ARCH=""
case "$(uname -m)" in
  x86_64|amd64)  ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  armv7l)        ARCH=armv7 ;;
  *) die "不支持的CPU架构: $(uname -m)" ;;
esac

PUBIP=$(curl -4 -fsS --max-time 10 https://api.ipify.org || curl -4 -fsS --max-time 10 https://ifconfig.me || true)
[ -n "$PUBIP" ] || die "无法获取公网IP"
log "公网IP: $PUBIP"

# ---------- 3. 安装 3x-ui ----------
log "安装 3x-ui(GitHub 最新 release)"
systemctl stop x-ui 2>/dev/null || true
TAG=$(curl -fsSL --max-time 20 https://api.github.com/repos/MHSanaei/3x-ui/releases/latest | jq -r '.tag_name // empty')
[ -n "$TAG" ] || die "获取 3x-ui 版本失败(GitHub API 不可达?)"
cd /tmp || die "无法进入 /tmp"
curl -fL --retry 3 -o x-ui.tgz "https://github.com/MHSanaei/3x-ui/releases/download/${TAG}/x-ui-linux-${ARCH}.tar.gz" \
  || die "下载 3x-ui ${TAG} 失败"
rm -rf /usr/local/x-ui
tar -xzf x-ui.tgz -C /usr/local/ || die "解压失败"
chmod +x /usr/local/x-ui/x-ui /usr/local/x-ui/bin/xray-linux-* 2>/dev/null || true
[ -f /usr/local/x-ui/x-ui.sh ] && { cp -f /usr/local/x-ui/x-ui.sh /usr/bin/x-ui; chmod +x /usr/bin/x-ui; }

SVC_NAME=x-ui.service.debian; [ "$PM" = rhel ] && SVC_NAME=x-ui.service.rhel
curl -fsSL --max-time 20 -o /etc/systemd/system/x-ui.service \
  "https://raw.githubusercontent.com/MHSanaei/3x-ui/main/$SVC_NAME" 2>/dev/null \
  || cp -f "/usr/local/x-ui/$SVC_NAME" /etc/systemd/system/x-ui.service
systemctl daemon-reload
systemctl enable x-ui >/dev/null 2>&1

# 面板端口需要空闲
port_free "$XUI_PORT" || { warn "面板端口 $XUI_PORT 被占用, 自动换一个"; XUI_PORT=$(shuf -i 20000-60000 -n1); }
USED+=" $XUI_PORT "

/usr/local/x-ui/x-ui setting -username "$XUI_USER" -password "$XUI_PASS" \
  -port "$XUI_PORT" -webBasePath "$BASE" >/dev/null 2>&1 || warn "x-ui setting 命令失败"
systemctl restart x-ui
sleep 4
systemctl is-active --quiet x-ui || die "x-ui 启动失败, 查看: journalctl -u x-ui -n 50"
log "3x-ui 已运行: 端口 $XUI_PORT 路径 $BASE"

# ---------- 4. 证书(有域名时) ----------
CERT=""; KEY=""
if [ -n "$DOMAIN" ]; then
  log "检查域名解析并申请证书: $DOMAIN"
  RESOLVED=$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk '{print $1; exit}')
  [ "$RESOLVED" = "$PUBIP" ] || warn "域名解析($RESOLVED)与本机IP($PUBIP)不一致, 证书可能失败"
  [ -d ~/.acme.sh ] || curl -fsSL https://get.acme.sh | sh -s "email=admin@$DOMAIN" >/dev/null 2>&1
  STOPPED=""
  if ! port_free 80; then
    for s in nginx apache2 httpd caddy; do
      if systemctl is-active --quiet "$s" 2>/dev/null; then systemctl stop "$s"; STOPPED+=" $s"; fi
    done
  fi
  ~/.acme.sh/acme.sh --issue -d "$DOMAIN" --standalone --server letsencrypt --force >>"$LOG" 2>&1
  CERT_DIR=$OUT_DIR/cert; mkdir -p "$CERT_DIR"
  ~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" \
    --key-file "$CERT_DIR/key.pem" --fullchain-file "$CERT_DIR/cert.pem" >>"$LOG" 2>&1
  for s in $STOPPED; do systemctl start "$s" 2>/dev/null; done
  if [ -s "$CERT_DIR/cert.pem" ] && [ -s "$CERT_DIR/key.pem" ]; then
    CERT="$CERT_DIR/cert.pem"; KEY="$CERT_DIR/key.pem"
    log "证书就绪"
  else
    warn "证书申请失败, 跳过 TLS 类节点(仅生成 Reality/SS2022)"
  fi
fi

# ---------- 5. 生成节点 ----------
log "生成节点密钥与端口"
XRAY=$(ls /usr/local/x-ui/bin/xray-linux-* 2>/dev/null | head -1)
KEYS=$("$XRAY" x25519 2>/dev/null)
PRIV=$(echo "$KEYS" | awk -F': ' '/Private/{print $2}' | tr -d ' \r')
PUB=$(echo "$KEYS" | awk -F': ' '/Public|Password/{print $2}' | tr -d ' \r')
[ -n "$PRIV" ] && [ -n "$PUB" ] || die "生成 Reality 密钥失败"
SHORT=$(openssl rand -hex 8)
UUID1=$(cat /proc/sys/kernel/random/uuid)
UUID2=$(cat /proc/sys/kernel/random/uuid)
UUID3=$(cat /proc/sys/kernel/random/uuid)
TROJAN_PW=$(rand_mix 16)
SS_PW=$(openssl rand -base64 16 | tr -d '\n')
SS_METHOD=2022-blake3-aes-128-gcm

API="http://127.0.0.1:${XUI_PORT}${BASE}"
COOKIE=$OUT_DIR/cookie.txt
login() {
  curl -s -c "$COOKIE" -X POST "${API}login" \
    -d "username=${XUI_USER}&password=${XUI_PASS}" | jq -e '.success==true' >/dev/null
}
api() { # api METHOD PATH [JSON]
  if [ -n "${3:-}" ]; then
    curl -s -b "$COOKIE" -H 'Content-Type: application/json' -X "$1" "${API}$2" -d "$3"
  else
    curl -s -b "$COOKIE" -X "$1" "${API}$2"
  fi
}

login || die "登录 3x-ui API 失败(账号/路径异常)"

# add_inbound <备注> <端口> <协议> <settings JSON> <stream JSON>
add_inbound() {
  local existing body res
  existing=$(api GET panel/api/inbounds/list | jq -r '.obj[]?.remark' 2>/dev/null)
  if echo "$existing" | grep -qxF "$1"; then warn "节点已存在, 跳过: $1"; return 0; fi
  body=$(jq -cn --arg r "$1" --argjson p "$2" --arg pr "$3" --arg s "$4" --arg st "$5" '{
    up:0, down:0, total:0, remark:$r, enable:true, expiryTime:0, listen:"",
    port:$p, protocol:$pr, settings:$s, streamSettings:$st,
    sniffing:"{\"enabled\":true,\"destOverride\":[\"http\",\"tls\",\"quic\"]}",
    allocate:"{\"strategy\":\"always\",\"refresh\":5,\"concurrency\":3}"}')
  res=$(api POST panel/api/inbounds/add "$body")
  if echo "$res" | jq -e '.success==true' >/dev/null 2>&1; then
    log "已创建节点: $1 (端口 $2)"; return 0
  fi
  warn "创建节点失败: $1 -> $res"; return 1
}

SNI="$REALITY_SNI"
# 5.1 VLESS + Reality (无需域名, 最常用)
take_port 443; P_REAL=$RET
S=$(jq -cn --arg id "$UUID1" '{clients:[{id:$id,flow:"xtls-rprx-vision",email:"reality@xui",limitIp:0,totalGB:0,expiryTime:0,enable:true,tgId:"",subId:"'"$SUBID"'",reset:0}],decryption:"none",fallbacks:[]}')
ST=$(jq -cn --arg pk "$PRIV" --arg pub "$PUB" --arg sid "$SHORT" --arg sni "$SNI" '{
  network:"tcp", security:"reality",
  realitySettings:{show:false, dest:($sni+":443"), xver:0, serverNames:[$sni], privateKey:$pk,
    minClientVer:"", maxClientVer:"", maxTimeDiff:0, shortIds:[$sid],
    settings:{publicKey:$pub, fingerprint:"chrome", serverName:"", spiderX:"/"}},
  tcpSettings:{acceptProxyProtocol:false, header:{type:"none"}}}')
add_inbound "VLESS-Reality" "$P_REAL" vless "$S" "$ST"

# 5.2 Shadowsocks 2022 (无需域名)
take_port ""; P_SS=$RET
S=$(jq -cn --arg m "$SS_METHOD" --arg pw "$SS_PW" '{method:$m, password:$pw, network:"tcp,udp", ivCheck:false}')
ST='{"network":"tcp","security":"none"}'
add_inbound "SS2022" "$P_SS" shadowsocks "$S" "$ST"

if [ -n "$CERT" ]; then
  # 5.3 VLESS + WS + TLS
  take_port 443; P_WS=$RET
  S=$(jq -cn --arg id "$UUID2" '{clients:[{id:$id,email:"vlesswstls@xui",limitIp:0,totalGB:0,expiryTime:0,enable:true,tgId:"",subId:"'"$SUBID"'",reset:0}],decryption:"none",fallbacks:[]}')
  ST=$(jq -cn --arg c "$CERT" --arg k "$KEY" --arg d "$DOMAIN" '{network:"ws", security:"tls",
    wsSettings:{path:"/vlessws", headers:{}},
    tlsSettings:{serverName:$d, minVersion:"1.2", alpn:["http/1.1"], certificates:[{certificateFile:$c, keyFile:$k, usage:"encipherment"}]}}')
  add_inbound "VLESS-WS-TLS" "$P_WS" vless "$S" "$ST"

  # 5.4 VMess + WS + TLS
  take_port ""; P_VM=$RET
  S=$(jq -cn --arg id "$UUID3" '{clients:[{id:$id,alterId:0,email:"vmesswstls@xui",limitIp:0,totalGB:0,expiryTime:0,enable:true,tgId:"",subId:"'"$SUBID"'",reset:0}],disableInsecureEncryption:false}')
  ST=$(jq -cn --arg c "$CERT" --arg k "$KEY" --arg d "$DOMAIN" '{network:"ws", security:"tls",
    wsSettings:{path:"/vmessws", headers:{}},
    tlsSettings:{serverName:$d, minVersion:"1.2", alpn:["http/1.1"], certificates:[{certificateFile:$c, keyFile:$k, usage:"encipherment"}]}}')
  add_inbound "VMess-WS-TLS" "$P_VM" vmess "$S" "$ST"

  # 5.5 Trojan + TLS
  take_port ""; P_TR=$RET
  S=$(jq -cn --arg pw "$TROJAN_PW" '{clients:[{password:$pw,email:"trojan@xui",limitIp:0,totalGB:0,expiryTime:0,enable:true,tgId:"",subId:"'"$SUBID"'",reset:0}],fallbacks:[]}')
  ST=$(jq -cn --arg c "$CERT" --arg k "$KEY" --arg d "$DOMAIN" '{network:"tcp", security:"tls",
    tcpSettings:{acceptProxyProtocol:false, header:{type:"none"}},
    tlsSettings:{serverName:$d, minVersion:"1.2", alpn:["http/1.1"], certificates:[{certificateFile:$c, keyFile:$k, usage:"encipherment"}]}}')
  add_inbound "Trojan-TLS" "$P_TR" trojan "$S" "$ST"
fi

# ---------- 6. 开启订阅服务 ----------
log "配置订阅服务"
SUB_PORT=$(take_port ""; echo "$RET")
DBF=/etc/x-ui/x-ui.db
[ -f "$DBF" ] || die "找不到数据库 $DBF"
set_setting() {
  sqlite3 "$DBF" "DELETE FROM settings WHERE key='$1'; INSERT INTO settings(key,value) VALUES('$1','$2');"
}
set_setting subEnable true
set_setting subPort "$SUB_PORT"
set_setting subPath "$SUB_PATH"
set_setting subJsonEnable false
if [ -n "$CERT" ]; then
  set_setting subCertFile "$CERT"
  set_setting subKeyFile "$KEY"
  SUB_HOST=$DOMAIN; SUB_SCHEME=https
else
  SUB_HOST=$PUBIP; SUB_SCHEME=http
fi
systemctl restart x-ui; sleep 4
systemctl is-active --quiet x-ui || die "重启 x-ui 失败"

# ---------- 7. 防火墙放行 ----------
log "放行端口"
OPEN_PORTS="$XUI_PORT $SUB_PORT $P_REAL $P_SS"
[ -n "$CERT" ] && OPEN_PORTS+=" 80 443 $P_WS $P_VM $P_TR"
for p in $OPEN_PORTS; do
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow "$p"/tcp >/dev/null 2>&1; ufw allow "$p"/udp >/dev/null 2>&1
  fi
  if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
    firewall-cmd --permanent --add-port="$p"/tcp >/dev/null 2>&1
    firewall-cmd --permanent --add-port="$p"/udp >/dev/null 2>&1
  fi
  iptables -C INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null
  iptables -C INPUT -p udp --dport "$p" -j ACCEPT 2>/dev/null || iptables -I INPUT -p udp --dport "$p" -j ACCEPT 2>/dev/null
done
command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --reload >/dev/null 2>&1

# ---------- 8. 生成分享链接与订阅 ----------
log "生成节点链接与订阅"
LINKS=$OUT_DIR/links.txt
: > "$LINKS"
HOST=${DOMAIN:-$PUBIP}
echo "vless://${UUID1}@${PUBIP}:${P_REAL}?type=tcp&security=reality&pbk=${PUB}&fp=chrome&sni=${SNI}&flow=xtls-rprx-vision&sid=${SHORT}#VLESS-Reality" >> "$LINKS"
echo "ss://$(printf '%s' "${SS_METHOD}:${SS_PW}" | base64 -w0)@${PUBIP}:${P_SS}#SS2022" >> "$LINKS"
if [ -n "$CERT" ]; then
  echo "vless://${UUID2}@${DOMAIN}:${P_WS}?type=ws&security=tls&path=%2Fvlessws&host=${DOMAIN}&sni=${DOMAIN}#VLESS-WS-TLS" >> "$LINKS"
  VM_JSON=$(jq -cn --arg d "$DOMAIN" --arg id "$UUID3" --argjson p "$P_VM" '{v:"2",ps:"VMess-WS-TLS",add:$d,port:$p,id:$id,aid:"0",scy:"auto",net:"ws",type:"none",host:$d,path:"/vmessws",tls:"tls",sni:$d}')
  echo "vmess://$(printf '%s' "$VM_JSON" | base64 -w0)" >> "$LINKS"
  echo "trojan://${TROJAN_PW}@${DOMAIN}:${P_TR}?security=tls&sni=${DOMAIN}&type=tcp#Trojan-TLS" >> "$LINKS"
fi
base64 -w0 "$LINKS" > "$OUT_DIR/sub_base64.txt"

SUB_URL="${SUB_SCHEME}://${HOST}:${SUB_PORT}${SUB_PATH}${SUBID}"
echo "$SUB_URL" > "$OUT_DIR/subscription_url.txt"

cat > "$OUT_DIR/info.txt" <<EOF
3x-ui 面板:   http://${PUBIP}:${XUI_PORT}${BASE}
面板账号:     ${XUI_USER}
面板密码:     ${XUI_PASS}
一键订阅链接: ${SUB_URL}
节点明文链接: ${LINKS}
EOF
chmod 600 "$OUT_DIR/info.txt" "$OUT_DIR/cookie.txt" 2>/dev/null || true
rm -f "$COOKIE"

# 订阅可达性检查(只能确认本机监听)
if ss -lnt | awk '{print $4}' | grep -qE "[:.]${SUB_PORT}\$"; then
  log "订阅端口 $SUB_PORT 已监听"
else
  warn "订阅端口 $SUB_PORT 未监听, 检查 3x-ui 设置是否生效"
fi

echo
log "部署完成"
cat "$OUT_DIR/info.txt"
echo "注意: 请确认云厂商安全组同样放行上面的端口。"
