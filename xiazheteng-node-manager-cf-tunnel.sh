#!/usr/bin/env bash
# 瞎折腾一键脚本（修复版） | Debian 12/13、Ubuntu 22.04/24.04 | amd64/arm64
set -Eeuo pipefail
[[ ${EUID} -eq 0 ]] || { echo '请使用 root 或 sudo bash x.sh'; exit 1; }
[[ -r /etc/os-release ]] || { echo '无法识别系统'; exit 1; }
. /etc/os-release
case "${ID}:${VERSION_ID}" in
  debian:12|debian:13|ubuntu:22.04|ubuntu:24.04) ;;
  *) echo '仅支持 Debian 12/13、Ubuntu 22.04/24.04'; exit 1 ;;
esac
case "$(uname -m)" in x86_64|aarch64) ;; *) echo '仅支持 amd64/arm64'; exit 1 ;; esac
command -v systemctl >/dev/null && [[ -d /run/systemd/system ]] || { echo '需要 systemd，不能在普通 Docker 容器中运行'; exit 1; }
[[ -r /dev/tty ]] || { echo '需要交互终端，请先下载，再执行 bash x.sh'; exit 1; }
exec </dev/tty
export DEBIAN_FRONTEND=noninteractive
workdir=$(mktemp -d /tmp/xiazt.XXXXXXXX)
awake_pid=''
cleanup() {
  [[ -z "$awake_pid" ]] || kill "$awake_pid" 2>/dev/null || true
  rm -f -- "$workdir/manager.py"
  rmdir -- "$workdir" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
if command -v systemd-inhibit >/dev/null; then
  systemd-inhibit --what=idle:sleep --who=xiazt --why='节点部署进行中' --mode=block sleep infinity >/dev/null 2>&1 &
  awake_pid=$!
fi
setterm --blank 0 --powersave off </dev/tty 2>/dev/null || true
if ! command -v python3 >/dev/null; then
  apt-get update
  apt-get install -y python3 ca-certificates
fi
cat >"$workdir/manager.py" <<'XIAZT_PYTHON_EOF_938715'
#!/usr/bin/env python3
"""瞎折腾：专用 3x-ui/Xray 实例，独立管理、可审计（修复版）。"""
import base64
import concurrent.futures
import contextlib
import getpass
import hashlib
import http.cookiejar
import ipaddress
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import socket
import sqlite3
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import unicodedata
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = Path('/opt/xiazt')
STATE = ROOT / 'state.json'
NAMES = ['xiazt-panel', 'xiazt-edge', 'xiazt-cf']
SCHEMES = ('vless://', 'vmess://', 'trojan://', 'ss://', 'ssr://',
           'hysteria2://', 'hy2://', 'tuic://', 'hysteria://', 'wireguard://')
MAX_BODY = 4 * 1024 * 1024
DEFAULT_SUB_NAME = '我的订阅'
# 修复：替换 microsoft.com 为 apple.com，防止 TLS 证书链过大导致 Xray 握手崩溃
DEFAULT_REALITY_TARGET = 'www.apple.com'
BANNER = """
⢠⣶⣶⣶⡆⣤⣤⣤⣿⣿⣤⣤⣤⠀  ⠀⢸⣿⡇⠀⢰⣶⣶⣶⣶⣶⣿⣷⠀  ⠀⣶⣶⣶⣶⢰⣿⣆⣿⣟⣰⣿⡆⠀  ⠀⣶⣶⣶⡆⠀⣿⡇⠀⣶⣶⣶⣦⠀  ⠀⠀⠀⠀⠀⠀⣿⡇⠀⠀⠀⠀⠀⠀
⢸⣿⠁⣿⡇⢿⣋⣉⣭⣭⣉⣙⡿⠀  ⠸⢿⣿⡿⠿⢸⣿⠉⠉⠀⠀⠀⠀⠀  ⠀⣿⡇⣸⣿⠘⠛⢻⣿⡟⠛⠛⠛⠀  ⠀⣿⡇⣿⡇⠿⣿⣿⠇⣿⡏⢹⣿⠀  ⠰⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⡷⠀
⢸⣿⠿⣿⡇⢘⣛⣛⣿⣿⣛⣛⡃⠀  ⠀⢸⣿⡇⠀⢸⣿⣷⣶⣶⣶⣶⣶⡆  ⠀⣿⡿⢿⣿⠛⣻⣿⡟⠻⣿⣟⠛⠀  ⠀⣿⡿⣿⣇⣀⣿⣧⣀⣿⡇⢸⣿⠀  ⠀⠀⠀⠀⣰⣿⣿⣿⣷⡀⠀⠀⠀⠀
⢸⣿⣤⣿⡇⣬⣭⣭⣿⣿⣭⣭⣥⠀  ⣤⣾⣿⣿⠿⢸⣿⠁⠀⢸⣿⡇⠀⠀  ⠀⣿⣧⣼⣿⢾⣿⡿⠿⢿⣿⠿⡷⠂  ⠀⣿⣇⣿⡟⢻⣿⣟⠛⣿⡇⢸⣿⠀  ⠀⠀⣠⣾⡿⠉⣿⡏⠹⣿⣦⡀⠀⠀
⢸⣿⠋⣿⡇⢩⣭⣭⣿⣿⣭⣭⡍⠀  ⠈⢸⣿⡇⠀⣿⣿⠀⠀⢸⣿⡇⠀⠀  ⢀⣿⡟⢻⣿⠀⠿⠿⠶⠾⠿⣷⡖⠀  ⢀⣿⠟⣿⣇⣾⡟⢿⣆⣿⡇⣸⣿⠀  ⢠⣾⡿⣯⣤⣬⣿⣧⣤⣬⡿⣿⡷⠀
⢸⣿⣶⣿⡇⢸⣿⣉⣉⣉⣉⣿⡇⠀  ⢀⣸⣿⡇⢼⣿⠇⠀⠀⢸⣿⡇⠀⠀  ⣸⣿⣇⣼⣿⠻⠿⠿⠟⠛⢃⣿⡇⠀  ⢸⣿⣀⣿⡿⣿⡷⠿⣿⣿⡿⠿⠏⠀  ⠀⠙⠁⠛⠛⠻⣿⡟⠛⠛⠃⠈⠁⠀
⠘⠛⠉⠛⠃⠸⠿⠛⠛⠛⠛⠿⠇⠀  ⠘⠛⠛⠁⠀⠉⠀⠀⠀⠘⠛⠃⠀⠀  ⠈⠏⠘⠛⠋⠀⠀⠀⠈⠛⠛⠛⠁⠀  ⠘⠏⠛⠛⠁⠀⠀⠀⠀⠿⠇⠀⠀⠀  ⠀⠀⠀⠀⠀⠀⠿⠇⠀⠀⠀⠀⠀⠀
"""

def run(*args, capture=False, check=True):
    p = subprocess.run(args, text=True, stdout=subprocess.PIPE if capture else None,
                       stderr=subprocess.PIPE if capture else None)
    if check and p.returncode:
        raise RuntimeError(f'{args[0]} 执行失败（退出码 {p.returncode}），请检查服务日志')
    return p.stdout.strip() if capture else p.returncode

def write(path, data, mode=0o600):
    path = Path(path)
    tmp = path.with_name(path.name + '.' + secrets.token_hex(6) + '.tmp')
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, mode)
    with os.fdopen(fd, 'w', encoding='utf-8', newline='\n') as f:
        f.write(data)
    os.chmod(tmp, mode)
    os.replace(tmp, path)

def save(c):
    write(STATE, json.dumps(c, ensure_ascii=False, indent=2))

def load():
    return json.loads(STATE.read_text(encoding='utf-8'))

def request(url, data=None, headers=None, method=None, opener=None):
    body = json.dumps(data).encode() if data is not None else None
    h = {'User-Agent': 'xiazt/1.0', **(headers or {})}
    if body is not None:
        h['Content-Type'] = 'application/json'
    req = urllib.request.Request(url, body, h, method=method)
    with (opener or urllib.request.build_opener()).open(req, timeout=25) as r:
        raw = r.read(MAX_BODY + 1)
        if len(raw) > MAX_BODY:
            raise ValueError('响应超过 4 MiB')
        return json.loads(raw)

def ask(prompt, default=''):
    return input(prompt).strip() or default

def domain(value):
    value = value.lower().rstrip('.')
    if len(value) > 253 or not re.fullmatch(r'(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}', value):
        raise ValueError('请输入纯域名，不带 https://、端口或路径；中文域名请用 punycode')
    return value

def public_ip(value):
    ip = ipaddress.ip_address(value)
    if not ip.is_global:
        raise ValueError('需要公网 IPv4/IPv6 地址')
    return str(ip)

def detect_public_ip():
    for url in ('https://api.ipify.org', 'https://ipv4.icanhazip.com', 'https://api6.ipify.org'):
        try:
            with urllib.request.urlopen(url, timeout=8) as r:
                return public_ip(r.read(100).decode().strip())
        except (OSError, ValueError, UnicodeError):
            pass
    if shutil.which('ip'):
        try:
            interfaces = json.loads(run('ip', '-j', 'address', 'show', 'scope', 'global', capture=True))
            addresses = [a['local'] for interface in interfaces for a in interface.get('addr_info', [])]
            for address in sorted(addresses, key=lambda a: ':' in a):
                try:
                    return public_ip(address)
                except ValueError:
                    pass
        except (OSError, ValueError, RuntimeError, KeyError):
            pass
    raise RuntimeError('无法自动识别 VPS 公网 IP，请检查网络后从安装菜单重试')

def panel_credentials():
    username = ask('3x-ui 后台账号 [回车随机生成]：', 'xzt_' + secrets.token_hex(4))
    if any(unicodedata.category(ch).startswith('C') for ch in username):
        raise ValueError('3x-ui 后台账号不能包含控制字符')
    while True:
        password = getpass.getpass('3x-ui 后台密码 [至少 12 个字符；回车随机生成]：') or secrets.token_urlsafe(24)
        if len(password) >= 12:
            return username, password
        print('输入错误：3x-ui 后台密码不能少于 12 个字符，请重新输入。')

def port_free(port):
    for family, address in [(socket.AF_INET, '0.0.0.0'), (socket.AF_INET6, '::')]:
        with socket.socket(family) as s:
            try:
                s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                if family == socket.AF_INET6:
                    s.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
                s.bind((address, port))
            except OSError as e:
                if e.errno not in (97, 99):
                    return False
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
        try:
            s.bind(('0.0.0.0', port))
        except OSError:
            return False
    return True

def choose_port(preferred):
    for p in [preferred] + [secrets.randbelow(30000) + 20000 for _ in range(100)]:
        if port_free(p):
            return p
    raise RuntimeError('找不到空闲 TCP 端口')

def image(ref):
    run('docker', 'pull', '--quiet', ref)
    digests = json.loads(run('docker', 'image', 'inspect', ref,
                             '--format', '{{json .RepoDigests}}', capture=True))
    if not digests:
        raise RuntimeError('镜像缺少摘要，拒绝启动未锁定镜像')
    return digests[0]

def container(name, img, *args, entrypoint=None, volumes=(), env=()):
    cmd = ['docker', 'run', '-d', '--name', name, '--network', 'host',
           '--restart', 'unless-stopped', '--label', 'io.xiazt.owner=1',
           '--log-opt', 'max-size=10m', '--log-opt', 'max-file=2']
    for host, guest in volumes:
        cmd += ['-v', f'{host}:{guest}']
    for v in env:
        cmd += ['-e', v]
    if entrypoint:
        cmd += ['--entrypoint', entrypoint]
    run(*cmd, img, *args, capture=True)

def owned(name):
    return run('docker', 'inspect', '--format',
               '{{index .Config.Labels "io.xiazt.owner"}}', name,
               capture=True, check=False) == '1'

def panel_cli(c, *args):
    return run('docker', 'run', '--rm', '--network', 'none',
               '-v', f'{ROOT}/db:/etc/x-ui', '--entrypoint', '/app/x-ui',
               c['panel_image'], 'setting', *args, capture=True)

class Panel:
    def __init__(self, c):
        self.c = c
        self.base = f"http://127.0.0.1:{c['panel_port']}{c['panel_path']}"
        self.opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))
        self.csrf = ''

    def call(self, path, data=None):
        headers = {'X-CSRF-Token': self.csrf} if self.csrf else {}
        obj = request(self.base + path, data, headers=headers, opener=self.opener)
        if not obj.get('success'):
            raise RuntimeError('3x-ui API 拒绝请求：' + str(obj.get('msg', '未知错误')))
        return obj.get('obj')

    def login(self):
        self.csrf = self.call('csrf-token')
        self.call('login', {'username': self.c['username'], 'password': self.c['password']})
        self.csrf = self.call('csrf-token')

    def wait(self):
        for _ in range(60):
            try:
                self.login()
                return
            except (OSError, ValueError, RuntimeError):
                time.sleep(1)
        raise RuntimeError('3x-ui 登录失败；状态已保留，运行 x 查看日志/继续配置')

def cf(c, path, data=None, method=None):
    obj = request('https://api.cloudflare.com/client/v4' + path, data,
                  {'Authorization': 'Bearer ' + c['cf_api_token']}, method)
    if not obj.get('success'):
        raise RuntimeError('Cloudflare API 失败：' + str(obj.get('errors', [])))
    return obj.get('result')

def ensure_firewall_ports(c):
    """自动放行本机防火墙端口，防止外部测试连通性显示 -1"""
    ports = [c['reality_port'], c['ss_port']]
    if c.get('domain'):
        ports.extend([80, 443])
    if shutil.which('ufw'):
        try:
            status = run('ufw', 'status', capture=True, check=False)
            if 'active' in status.lower() and 'inactive' not in status.lower():
                for p in ports:
                    run('ufw', 'allow', f'{p}/tcp', check=False)
                    if p == c['ss_port']:
                        run('ufw', 'allow', f'{p}/udp', check=False)
                print(f'已在 UFW 防火墙自动放行端口：{ports}')
        except Exception:
            pass
    if shutil.which('iptables'):
        try:
            for p in ports:
                run('iptables', '-I', 'INPUT', '-p', 'tcp', '--dport', str(p), '-j', 'ACCEPT', check=False)
                if p == c['ss_port']:
                    run('iptables', '-I', 'INPUT', '-p', 'udp', '--dport', str(p), '-j', 'ACCEPT', check=False)
        except Exception:
            pass

def resolve_cf_identity(c):
    host = c['cf_hostname']
    parts = host.split('.')
    for i in range(len(parts) - 1):
        zones = cf(c, '/zones?name=' + '.'.join(parts[i:]))
        if zones:
            zone = zones[0]
            account = zone.get('account', {}).get('id')
            if not account:
                raise RuntimeError('Cloudflare 未返回域名所属账户，请检查 API Token 的资源范围与 Zone Read 权限')
            c['cf_zone'], c['cf_account'] = zone['id'], account
            return
    raise RuntimeError('找不到该域名的 Cloudflare Zone，检查 API Token 的 Zone Read 权限和域名范围')

def setup_cf(c):
    host = c['cf_hostname']
    resolve_cf_identity(c)
    zone = c['cf_zone']
    existing = cf(c, f'/zones/{zone}/dns_records?name={host}')
    if existing and not (c.get('cf_dns_id') and existing[0]['id'] == c['cf_dns_id']):
        raise RuntimeError('固定隧道域名已有 DNS 记录；请换一个空闲子域名，脚本不会覆盖现有记录')
    account = c['cf_account']
    if not c.get('cf_tunnel_id'):
        tunnel = cf(c, f'/accounts/{account}/cfd_tunnel',
                    {'name': 'xiazt-' + secrets.token_hex(5), 'config_src': 'cloudflare'})
        c['cf_tunnel_id'] = tunnel['id']
        save(c)
    tid = c['cf_tunnel_id']
    cf(c, f'/accounts/{account}/cfd_tunnel/{tid}/configurations', {'config': {'ingress': [
        {'hostname': host, 'service': f"http://127.0.0.1:{c['edge_port']}"},
        {'service': 'http_status:404'}]}}, 'PUT')
    if not c.get('cf_dns_id'):
        record = cf(c, f'/zones/{zone}/dns_records', {'type': 'CNAME', 'name': host,
                    'content': tid + '.cfargotunnel.com', 'proxied': True, 'ttl': 1})
        c['cf_dns_id'] = record['id']
        save(c)
    token = cf(c, f'/accounts/{account}/cfd_tunnel/{tid}/token')
    write(ROOT / 'cf-token', token, 0o644)

def setup_nodes(c):
    api = Panel(c)
    api.wait()
    # 修复旧配置中使用的失效 SNI（microsoft.com 证书过长导致 Xray 握手失败）
    if c.get('sni') in ('www.microsoft.com', 'microsoft.com', None, ''):
        c['sni'] = DEFAULT_REALITY_TARGET
        save(c)
    inbound_list = api.call('panel/api/inbounds/list')
    # 若存在旧版失效的 reality 入站（目标域名为 microsoft 或缺少 minClientVer），先删除后重建
    for item in inbound_list:
        if item.get('remark') == 'xiazt-reality':
            try:
                stream_obj = json.loads(item.get('streamSettings', '{}'))
                rs = stream_obj.get('realitySettings', {})
                if 'microsoft.com' in rs.get('dest', '') or rs.get('minClientVer') != '1.0.0':
                    api.call(f"panel/api/inbounds/del/{item['id']}")
            except Exception:
                pass
    existing = {i['remark'] for i in api.call('panel/api/inbounds/list')}
    def add(name, port, protocol, settings, stream, listen='127.0.0.1'):
        if name in existing:
            return
        api.call('panel/api/inbounds/add', {'remark': name, 'enable': True,
                 'listen': listen, 'port': port, 'protocol': protocol,
                 'settings': json.dumps(settings), 'streamSettings': json.dumps(stream),
                 'sniffing': json.dumps({'enabled': True, 'destOverride': ['http', 'tls']}),
                 'allocate': json.dumps({'strategy': 'always', 'refresh': 5, 'concurrency': 3})})
    for proto in ('vless', 'vmess', 'trojan'):
        client = {'id': c['uuid'], 'email': 'xiazt-' + proto, 'enable': True,
                  'subId': c['sub_token'], 'totalGB': 0, 'expiryTime': 0,
                  'limitIp': 0, 'reset': 0}
        if proto == 'trojan':
            client['password'] = c['node_password']
        if proto == 'vmess':
            client['alterId'] = 0
        settings = {'clients': [client]}
        if proto == 'vless':
            settings['decryption'] = 'none'
        add('xiazt-' + proto + '-ws', c[proto + '_port'], proto, settings,
            {'network': 'ws', 'security': 'none',
             'wsSettings': {'path': c['ws_prefix'] + '/' + proto, 'headers': {}}})
    # 修复：显式加入 minClientVer: 1.0.0 避免 Xray-core 新版本默认拦截旧客户端
    add('xiazt-reality', c['reality_port'], 'vless',
        {'clients': [{'id': c['uuid'], 'email': 'xiazt-reality', 'enable': True,
                      'flow': 'xtls-rprx-vision', 'subId': c['sub_token']}], 'decryption': 'none'},
        {'network': 'tcp', 'security': 'reality', 'realitySettings': {
            'show': False, 'target': c['sni'] + ':443', 'dest': c['sni'] + ':443',
            'xver': 0, 'serverNames': [c['sni']], 'privateKey': c['private_key'],
            'minClientVer': '1.0.0', 'maxClientVer': '', 'maxTimeDiff': 0,
            'shortIds': [c['short_id']], 'settings': {'publicKey': c['public_key'],
            'fingerprint': 'chrome', 'serverName': c['sni'], 'spiderX': '/'}}}, listen='::' if ':' in c['ip'] else '0.0.0.0')
    add('xiazt-shadowsocks', c['ss_port'], 'shadowsocks',
        {'method': 'chacha20-ietf-poly1305', 'password': c['node_password'],
         'network': 'tcp,udp'}, {'network': 'tcp', 'security': 'none'}, listen='::' if ':' in c['ip'] else '0.0.0.0')
    run('docker', 'restart', 'xiazt-panel', capture=True)
    api.wait()
    for p in [c[k + '_port'] for k in ('vless', 'vmess', 'trojan', 'reality', 'ss')]:
        for _ in range(30):
            try:
                conn_host = '::1' if ':' in c['ip'] else '127.0.0.1'
                with socket.create_connection((conn_host, p), timeout=1):
                    break
            except OSError:
                time.sleep(1)
        else:
            raise RuntimeError(f'Xray 未监听 {p}；不能报告部署成功。运行 x 查看日志')

def b64(s):
    return base64.b64encode(s.encode()).decode()

def subscription_name(value):
    if not isinstance(value, str) or any(unicodedata.category(ch).startswith('C') for ch in value):
        raise ValueError('订阅名称不能包含控制字符')
    value = value.strip()
    if not value or len(value) > 48:
        raise ValueError('订阅名称需为 1–48 个字符')
    return value

def link(scheme, user, host, port, query, name):
    host = '[' + host + ']' if ':' in host else host
    return f'{scheme}://{urllib.parse.quote(user, safe="")}@{host}:{port}?' + urllib.parse.urlencode(query) + '#' + urllib.parse.quote(name)

def quick_host():
    started = run('docker', 'inspect', '--format', '{{.State.StartedAt}}', 'xiazt-cf', capture=True, check=False)
    if not started:
        return ''
    p = subprocess.run(['docker', 'logs', '--since', started, '--tail', '200', 'xiazt-cf'], capture_output=True, text=True)
    matches = re.findall(r'https://([a-z0-9-]+\.trycloudflare\.com)', p.stdout + p.stderr)
    return matches[-1] if matches else ''

def endpoints(c):
    result = []
    if c['domain']:
        result.append(c['domain'])
    if c['tunnel'] == 'fixed':
        result.append(c['cf_hostname'])
    elif c['tunnel'] == 'quick':
        host = quick_host()
        if host:
            result.append(host)
    return list(dict.fromkeys(result))

def node_links(c, name=None):
    name = subscription_name(c.get('subscription_name', DEFAULT_SUB_NAME) if name is None else name)
    links = [link('vless', c['uuid'], c['ip'], c['reality_port'],
                  {'encryption': 'none', 'security': 'reality', 'sni': c['sni'],
                   'fp': 'chrome', 'pbk': c['public_key'], 'sid': c['short_id'],
                   'type': 'tcp', 'flow': 'xtls-rprx-vision', 'spx': '/'}, name + '-REALITY')]
    host = '[' + c['ip'] + ']' if ':' in c['ip'] else c['ip']
    links.append('ss://' + b64('chacha20-ietf-poly1305:' + c['node_password']) +
                 f"@{host}:{c['ss_port']}#" + urllib.parse.quote(name + '-SS'))
    cf_preferred = ['visa.cn', 'icook.hk', '104.16.160.1', '162.159.192.1']
    for host in endpoints(c):
        for proto in ('vless', 'trojan'):
            q = {'security': 'tls', 'sni': host, 'type': 'ws', 'host': host,
                 'path': c['ws_prefix'] + '/' + proto}
            if proto == 'vless':
                q['encryption'] = 'none'
            links.append(link(proto, c['uuid'] if proto == 'vless' else c['node_password'],
                              host, 443, q, name + '-' + proto + '-' + host))
        # 修复：port 与 aid 必须为整数，否则在部分客户端中解析失败报 -1
        links.append('vmess://' + b64(json.dumps({'v': '2', 'ps': name + '-vmess-' + host,
            'add': host, 'port': 443, 'id': c['uuid'], 'aid': 0, 'scy': 'auto',
            'net': 'ws', 'type': 'none', 'host': host, 'path': c['ws_prefix'] + '/vmess',
            'tls': 'tls', 'sni': host}, ensure_ascii=False)))
        # 固定隧道或自定义域名增加 Cloudflare 优选节点，避免国内 Anycast IP 丢包导致 -1
        if 'trycloudflare.com' not in host:
            for pref in cf_preferred:
                q_vless = {'security': 'tls', 'sni': host, 'type': 'ws', 'host': host,
                           'path': c['ws_prefix'] + '/vless', 'encryption': 'none'}
                links.append(link('vless', c['uuid'], pref, 443, q_vless, f"{name}-VLESS-优选-{pref}"))
                links.append('vmess://' + b64(json.dumps({'v': '2', 'ps': f"{name}-VMess-优选-{pref}",
                    'add': pref, 'port': 443, 'id': c['uuid'], 'aid': 0, 'scy': 'auto',
                    'net': 'ws', 'type': 'none', 'host': host, 'path': c['ws_prefix'] + '/vmess',
                    'tls': 'tls', 'sni': host}, ensure_ascii=False)))
    return links

def subscription_response(c, query, merged):
    names = query.get('name', [c.get('subscription_name', DEFAULT_SUB_NAME)])
    if len(names) != 1:
        raise ValueError('订阅名称只能指定一次')
    name = subscription_name(names[0])
    lines = list(dict.fromkeys(node_links(c, name) + merged))
    raw = '\n'.join(lines)
    body = (raw if query.get('format') == ['raw'] else b64(raw)).encode()
    headers = {'Profile-Title': 'base64:' + b64(name),
               'Content-Disposition': "inline; filename*=UTF-8''" + urllib.parse.quote(name + '.txt', safe='')}
    return body, headers

def parse_subscription(raw):
    text = raw.decode('utf-8-sig').strip()
    if not text:
        raise ValueError('空订阅')
    if not text.startswith(SCHEMES):
        try:
            text = base64.b64decode(re.sub(r'\s', '', text) + '===', altchars=b'-_', validate=False).decode().strip()
        except (ValueError, UnicodeError):
            raise ValueError('仅支持 URI 列表/Base64 订阅，不支持 Clash YAML 或 JSON')
    lines = [s.strip() for s in text.splitlines() if s.strip()]
    if not lines or any(not s.startswith(SCHEMES) for s in lines):
        raise ValueError('订阅含不支持的格式')
    return list(dict.fromkeys(lines))

class PublicHTTPS(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        validate_source(newurl)
        return super().redirect_request(req, fp, code, msg, headers, newurl)

def validate_source(url):
    u = urllib.parse.urlsplit(url)
    if u.scheme != 'https' or not u.hostname or u.username or u.password or u.port not in (None, 443):
        raise ValueError('外部订阅必须是公网 HTTPS URL（443）')
    addresses = socket.getaddrinfo(u.hostname, 443, type=socket.SOCK_STREAM)
    if not addresses or any(not ipaddress.ip_address(a[4][0]).is_global for a in addresses):
        raise ValueError('不接受内网/本机订阅地址')

def fetch_source(url):
    validate_source(url)
    opener = urllib.request.build_opener(PublicHTTPS())
    with opener.open(urllib.request.Request(url, headers={'User-Agent': 'v2rayN/xiazt'}), timeout=15) as r:
        raw = r.read(MAX_BODY + 1)
    if len(raw) > MAX_BODY:
        raise ValueError('外部订阅超过 4 MiB')
    return parse_subscription(raw)

def refresh_sources(c):
    cache = {}
    path = ROOT / 'cache.json'
    if path.exists():
        cache = json.loads(path.read_text())
    def fetch(url):
        try:
            return url, fetch_source(url), True
        except Exception:
            print('某个外部订阅刷新失败，沿用上次成功缓存', flush=True)
            return url, cache.get(url, {}).get('links', []), False
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        for url, links, ok in pool.map(fetch, c.get('sources', [])):
            old = cache.get(url, {})
            cache[url] = {'links': links, 'updated': int(time.time()) if ok else old.get('updated', 0)}
    cache = {u: cache[u] for u in c.get('sources', []) if u in cache}
    write(path, json.dumps(cache))
    return [v for obj in cache.values() for v in obj['links']]

def serve():
    merged = []
    lock = threading.Lock()
    def worker():
        nonlocal merged
        while True:
            try:
                result = refresh_sources(load())
                with lock:
                    merged = result
            except Exception:
                print('订阅缓存刷新失败', flush=True)
            time.sleep(300)
    threading.Thread(target=worker, daemon=True).start()
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass
        def do_GET(self):
            c = load()
            path = urllib.parse.urlsplit(self.path).path
            extra_headers = {}
            if path == '/health':
                body = b'ok'
            elif secrets.compare_digest(path, '/sub/' + c['sub_token']):
                query = urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query, keep_blank_values=True)
                try:
                    with lock:
                        body, extra_headers = subscription_response(c, query, merged)
                except ValueError:
                    self.send_error(400, 'Invalid subscription name')
                    return
            else:
                self.send_error(404)
                return
            self.send_response(200)
            self.send_header('Content-Type', 'text/plain; charset=utf-8')
            self.send_header('Cache-Control', 'no-store')
            for key, value in extra_headers.items():
                self.send_header(key, value)
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)
    server = ThreadingHTTPServer(('127.0.0.1', load()['sub_port']), Handler)
    server.daemon_threads = True
    server.serve_forever()

def caddy_config(c):
    routes = ''
    # 修复：加上 * 通配符，防止客户端携带斜杠或路径参数时返回 404
    for proto in ('vless', 'vmess', 'trojan'):
        routes += f"    handle {c['ws_prefix']}/{proto}* {{\n        reverse_proxy 127.0.0.1:{c[proto + '_port']}\n    }}\n"
    routes += f"    handle /sub/* {{\n        reverse_proxy 127.0.0.1:{c['sub_port']}\n    }}\n    handle /health {{\n        respond ok\n    }}\n    handle {{\n        respond 404\n    }}\n"
    config = '{\n    admin off\n'
    if not c.get('http_challenge', True):
        config += '    auto_https disable_redirects\n'
    config += '}\n'
    config += f"http://:{c['edge_port']} {{\n    bind 127.0.0.1\n" + routes + '}\n'
    if c['domain']:
        tls = '' if c.get('http_challenge', True) else '    tls {\n        issuer acme {\n            disable_http_challenge\n        }\n    }\n'
        config += c['domain'] + ' {\n' + tls + routes + '}\n'
    return config

def install_services(c):
    ensure_firewall_ports(c)
    write(ROOT / 'Caddyfile', caddy_config(c), 0o644)
    if not owned('xiazt-edge'):
        container('xiazt-edge', c['edge_image'], 'caddy', 'run', '--config', '/etc/caddy/Caddyfile',
                  volumes=[(ROOT / 'Caddyfile', '/etc/caddy/Caddyfile:ro'),
                           (ROOT / 'caddy-data', '/data'), (ROOT / 'caddy-config', '/config')])
    else:
        run('docker', 'restart', 'xiazt-edge', capture=True)
    write('/etc/systemd/system/xiazt-sub.service', '''[Unit]
Description=Xiazt subscription service
After=network-online.target docker.service
Wants=network-online.target
[Service]
ExecStart=/usr/bin/python3 /opt/xiazt/manager.py serve
Restart=on-failure
RestartSec=5
UMask=0077
NoNewPrivileges=true
ProtectSystem=strict
ReadWritePaths=/opt/xiazt
ProtectHome=true
PrivateTmp=true
[Install]
WantedBy=multi-user.target
''', 0o644)
    run('systemctl', 'daemon-reload')
    run('systemctl', 'enable', '--now', 'xiazt-sub.service')
    if owned('xiazt-cf'):
        run('docker', 'restart', 'xiazt-cf', capture=True)
    elif c['tunnel'] == 'fixed':
        setup_cf(c)
        container('xiazt-cf', c['cf_image'], 'tunnel', '--no-autoupdate', 'run',
                  '--token-file', '/run/cf-token', volumes=[(ROOT / 'cf-token', '/run/cf-token:ro')])
    elif c['tunnel'] == 'quick':
        container('xiazt-cf', c['cf_image'], 'tunnel', '--no-autoupdate', '--url',
                  f"http://127.0.0.1:{c['edge_port']}")

def verify_public(c):
    hosts = []
    for _ in range(90):
        hosts = endpoints(c)
        if hosts:
            break
        time.sleep(1)
    results = {}
    for host in hosts:
        ok = False
        for _ in range(30):
            try:
                req = urllib.request.Request(f"https://{host}/sub/{c['sub_token']}",
                                             headers={'User-Agent': 'v2rayN/xiazt'})
                with urllib
