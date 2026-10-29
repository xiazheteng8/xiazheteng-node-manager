#!/usr/bin/env bash
# 瞎折腾一键脚本 | Debian 12/13、Ubuntu 22.04/24.04 | amd64/arm64
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
"""瞎折腾：专用 3x-ui/Xray 实例，独立管理、可审计。"""
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
DEFAULT_REALITY_TARGET = 'www.microsoft.com'
# 中文字符点阵：瞎折腾脚本；78 列，无需服务器安装字体库。
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
        # Do not print argv: CLI arguments may contain passwords/tokens.
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
                # Reinstallation must tolerate recently closed TCP connections.
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
        save(c)  # record ownership before the next external mutation
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
    # The image runs as non-root; host parent directory remains root-only (0700).
    write(ROOT / 'cf-token', token, 0o644)


def setup_nodes(c):
    api = Panel(c)
    api.wait()
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
    add('xiazt-reality', c['reality_port'], 'vless',
        {'clients': [{'id': c['uuid'], 'email': 'xiazt-reality', 'enable': True,
                      'flow': 'xtls-rprx-vision', 'subId': c['sub_token']}], 'decryption': 'none'},
        {'network': 'tcp', 'security': 'reality', 'realitySettings': {
            'show': False, 'target': c['sni'] + ':443', 'dest': c['sni'] + ':443',
            'xver': 0, 'serverNames': [c['sni']], 'privateKey': c['private_key'],
            'shortIds': [c['short_id']], 'settings': {'publicKey': c['public_key'],
            'fingerprint': 'chrome', 'serverName': c['sni'], 'spiderX': '/'}}}, listen='::' if ':' in c['ip'] else '0.0.0.0')
    add('xiazt-shadowsocks', c['ss_port'], 'shadowsocks',
        {'method': 'chacha20-ietf-poly1305', 'password': c['node_password'],
         'network': 'tcp,udp'}, {'network': 'tcp', 'security': 'none'}, listen='::' if ':' in c['ip'] else '0.0.0.0')
    run('docker', 'restart', 'xiazt-panel', capture=True)
    api.wait()
    # API acceptance alone is insufficient: check actual listeners after core restart.
    for p in [c[k + '_port'] for k in ('vless', 'vmess', 'trojan', 'reality', 'ss')]:
        for _ in range(30):
            try:
                with socket.create_connection(('127.0.0.1', p), timeout=1):
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
    # cloudflared logs to stderr; gather both streams without leaking them.
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
                   'type': 'tcp', 'flow': 'xtls-rprx-vision'}, name + '-REALITY')]
    host = '[' + c['ip'] + ']' if ':' in c['ip'] else c['ip']
    links.append('ss://' + b64('chacha20-ietf-poly1305:' + c['node_password']) +
                 f"@{host}:{c['ss_port']}#" + urllib.parse.quote(name + '-SS'))
    for host in endpoints(c):
        for proto in ('vless', 'trojan'):
            q = {'security': 'tls', 'sni': host, 'type': 'ws', 'host': host,
                 'path': c['ws_prefix'] + '/' + proto}
            if proto == 'vless':
                q['encryption'] = 'none'
            links.append(link(proto, c['uuid'] if proto == 'vless' else c['node_password'],
                              host, 443, q, name + '-' + proto + '-' + host))
        links.append('vmess://' + b64(json.dumps({'v': '2', 'ps': name + '-vmess-' + host,
            'add': host, 'port': '443', 'id': c['uuid'], 'aid': '0', 'scy': 'auto',
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
            # Never log subscription URLs: query strings are credentials.
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
            pass  # prevent secret-bearing URLs appearing in logs
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
    for proto in ('vless', 'vmess', 'trojan'):
        routes += f"    handle {c['ws_prefix']}/{proto} {{\n        reverse_proxy 127.0.0.1:{c[proto + '_port']}\n    }}\n"
    routes += f"    handle /sub/* {{\n        reverse_proxy 127.0.0.1:{c['sub_port']}\n    }}\n    handle /health {{\n        respond ok\n    }}\n    handle {{\n        respond 404\n    }}\n"
    config = '{\n    admin off\n'
    if not c.get('http_challenge', True):
        config += '    auto_https disable_redirects\n'
    config += '}\n'
    # A site hostname matches the HTTP Host; it does not restrict the bind address.
    # CF forwards the public hostname, so accept any Host but bind loopback only.
    config += f"http://:{c['edge_port']} {{\n    bind 127.0.0.1\n" + routes + '}\n'
    if c['domain']:
        tls = '' if c.get('http_challenge', True) else '    tls {\n        issuer acme {\n            disable_http_challenge\n        }\n    }\n'
        config += c['domain'] + ' {\n' + tls + routes + '}\n'
    return config


def install_services(c):
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
                # Verify TLS and actual subscription, not just a listening socket.
                req = urllib.request.Request(f"https://{host}/sub/{c['sub_token']}",
                                             headers={'User-Agent': 'v2rayN/xiazt'})
                with urllib.request.urlopen(req, timeout=6) as r:
                    parsed = parse_subscription(r.read(MAX_BODY))
                    ok = len(parsed) >= 5
                if ok:
                    break
            except Exception:
                time.sleep(2)
        results[host] = ok
    c['public_checks'] = results
    save(c)
    if not hosts or not all(results.values()):
        print('公网订阅未验证通过：检查 DNS、80/443、安全组及 CF 日志。未标记部署成功。')
        return False
    return True


def show(c):
    print('订阅名称：' + c.get('subscription_name', DEFAULT_SUB_NAME))
    print('\n3x-ui 后台通过 SSH 转发访问：')
    sshhost = '[' + c['ip'] + ']' if ':' in c['ip'] else c['ip']
    print(f"ssh -N -L {c['panel_port']}:127.0.0.1:{c['panel_port']} root@{sshhost}")
    print(f"3x-ui 后台：http://127.0.0.1:{c['panel_port']}{c['panel_path']}")
    print('3x-ui 后台账号：' + c['username'] + '\n3x-ui 后台密码：' + c['password'])
    for host in endpoints(c):
        print(f"订阅：https://{host}/sub/{c['sub_token']}")
    print(f"需放行：TCP {c['reality_port']}；TCP/UDP {c['ss_port']}" +
          (('；TCP 80/443' if c.get('http_challenge', True) else '；TCP 443') + '（域名直连）' if c['domain'] else ''))
    print('WS 端口、后台、订阅源站只监听本机；不自动改动你的防火墙或云安全组。')
    if c['tunnel'] == 'quick':
        print('临时隧道重启会换域名：运行 x 查看新订阅。节点订阅内容会自动使用当前域名。')
    print('快捷管理：x；凭据保存：/opt/xiazt/state.json（root 专用）')


def install():
    # First installation prompt, as requested.
    host = ask('输入已解析的域名（没有就回车跳过）：')
    if host:
        host = domain(host)
    if STATE.exists():
        raise RuntimeError('已有专用实例，请使用 x 管理或先卸载；拒绝覆盖现有凭据')
    if ROOT.exists() and any(ROOT.iterdir()):
        raise RuntimeError('/opt/xiazt 已存在且非空，拒绝覆盖')
    if Path('/usr/local/bin/x').exists():
        raise RuntimeError('/usr/local/bin/x 已存在，拒绝覆盖已有快捷命令')
    for n in NAMES:
        if shutil.which('docker') and run('docker', 'inspect', '--format', '{{.Id}}', n, capture=True, check=False):
            raise RuntimeError(f'容器名 {n} 已存在，拒绝覆盖')
    tunnel = ask('CF 隧道：0 不使用 / 1 临时 / 2 固定 [' + ('0' if host else '1') + ']：', '0' if host else '1')
    if tunnel not in ('0', '1', '2'):
        raise ValueError('隧道选项必须是 0/1/2')
    if not host and tunnel == '0':
        raise ValueError('无域名时请选择临时或固定隧道，以提供 HTTPS 订阅')
    ip = detect_public_ip()
    sni = DEFAULT_REALITY_TARGET
    print('自动识别 VPS 公网 IP：' + ip)
    print('REALITY 目标域名自动设置为：' + sni)
    username, password = panel_credentials()
    custom_name = subscription_name(ask('自定义订阅名称 [我的订阅]：', DEFAULT_SUB_NAME))
    c = {'domain': host, 'ip': ip, 'tunnel': {'0': 'none', '1': 'quick', '2': 'fixed'}[tunnel],
         'username': username, 'password': password, 'panel_path': '/' + secrets.token_hex(12) + '/',
         'uuid': str(uuid.uuid4()), 'node_password': secrets.token_urlsafe(24),
         'sub_token': secrets.token_urlsafe(32), 'short_id': secrets.token_hex(8),
         'sni': sni, 'ws_prefix': '/' + secrets.token_hex(12), 'sources': [], 'complete': False,
         'subscription_name': custom_name}
    if tunnel == '2':
        c['cf_hostname'] = domain(ask('固定隧道域名（CF 托管的空闲子域名）：'))
        c['cf_api_token'] = getpass.getpass('Cloudflare API Token（Tunnel Edit / DNS Edit / Zone Read）：').strip()
        if not c['cf_api_token']:
            raise ValueError('API Token 不能为空')
        resolve_cf_identity(c)
        print('已自动识别 Cloudflare 域名区域及所属账户。')
    if host:
        try:
            resolved = {a[4][0] for a in socket.getaddrinfo(host, 443, type=socket.SOCK_STREAM)}
        except socket.gaierror:
            resolved = set()
        # A VPS hostname is commonly mapped to loopback in /etc/hosts.
        # Verify against public DNS before rejecting an otherwise valid domain.
        if ip not in resolved:
            for kind in ('A', 'AAAA'):
                answer = request('https://dns.google/resolve?' + urllib.parse.urlencode({'name': host, 'type': kind}))
                resolved.update(a['data'] for a in answer.get('Answer', []) if a['type'] in (1, 28))
        if ip not in resolved:
            raise ValueError('域名未解析到所选公网 IP。直连模式请关闭 CF 橙云，或改用固定隧道')
        if not port_free(443):
            raise RuntimeError('443 端口已占用；请使用隧道模式，脚本不会抢占服务')
        c['http_challenge'] = port_free(80)
        if not c['http_challenge']:
            print('80 端口已有服务，保留原服务；HTTPS 证书改用 443 TLS-ALPN 验证。')
    reserved = set()
    for name, preferred in [('panel', 20530), ('sub', 20531), ('edge', 20532),
                            ('vless', 20533), ('vmess', 20534), ('trojan', 20535),
                            ('reality', 8443), ('ss', 18443)]:
        p = choose_port(preferred)
        while p in reserved:
            p = choose_port(secrets.randbelow(30000) + 20000)
        c[name + '_port'] = p
        reserved.add(p)
    print('安装系统依赖；不会卸载或接管已有 3x-ui。')
    run('apt-get', 'update')
    run('apt-get', 'install', '-y', 'ca-certificates', 'curl', 'docker.io', 'openssl')
    run('systemctl', 'enable', '--now', 'docker')
    # Pull mutable upstream tags once, then record immutable repository digests.
    release = request('https://api.github.com/repos/MHSanaei/3x-ui/releases/latest')['tag_name']
    c['panel_version'] = release
    c['panel_image'] = image('ghcr.io/mhsanaei/3x-ui:' + release)
    c['edge_image'] = image('caddy:2')
    if tunnel != '0':
        c['cf_image'] = image('cloudflare/cloudflared:latest')
    ROOT.mkdir(mode=0o700, parents=True, exist_ok=True)
    (ROOT / 'db').mkdir(mode=0o700)
    save(c)
    shutil.copyfile(Path(__file__), ROOT / 'manager.py')
    os.chmod(ROOT / 'manager.py', 0o700)
    write('/usr/local/bin/x', '#!/bin/sh\nexec /usr/bin/python3 /opt/xiazt/manager.py "$@"\n', 0o755)
    resume(c)


def resume(c):
    # Configure an offline DB before starting the panel: no exposed default login.
    if not owned('xiazt-panel'):
        panel_cli(c, '-username', c['username'], '-password', c['password'],
              '-port', str(c['panel_port']), '-listenIP', '127.0.0.1', '-webBasePath', c['panel_path'])
        # Disable the upstream default public subscription listener before first boot.
        with sqlite3.connect(ROOT / 'db/x-ui.db') as db:
            for key, value in [('subEnable', 'false'), ('subListen', '127.0.0.1')]:
                db.execute('DELETE FROM settings WHERE key = ?', (key,))
                db.execute('INSERT INTO settings (key, value) VALUES (?, ?)', (key, value))
        container('xiazt-panel', c['panel_image'], volumes=[(ROOT / 'db', '/etc/x-ui')],
              env=['XUI_ENABLE_FAIL2BAN=false', 'TZ=Asia/Shanghai'])
    else:
        run('docker', 'start', 'xiazt-panel', capture=True)
    Panel(c).wait()
    # Derive X25519 keypair using host OpenSSL; independent of xray CLI output versions.
    if not c.get('private_key'):
        key = subprocess.check_output(['openssl', 'genpkey', '-algorithm', 'X25519'])
        private = subprocess.check_output(['openssl', 'pkey', '-outform', 'DER'], input=key)[-32:]
        public = subprocess.check_output(['openssl', 'pkey', '-pubout', '-outform', 'DER'], input=key)[-32:]
        c['private_key'] = base64.urlsafe_b64encode(private).decode().rstrip('=')
        c['public_key'] = base64.urlsafe_b64encode(public).decode().rstrip('=')
        save(c)
    setup_nodes(c)
    install_services(c)
    c['complete'] = verify_public(c)
    save(c)
    show(c)
    if not c['complete']:
        raise RuntimeError('部署未通过公网订阅检查，运行 x → 检查/恢复')
    print('服务与 HTTPS 订阅检查通过。真实代理通断仍需从客户端测试。')


def remove():
    c = load()
    if ask('删除本脚本全部节点、后台、凭据和订阅；输入 DELETE 确认：') != 'DELETE':
        return
    # Do not silently leave externally-created resources behind.
    if c.get('cf_tunnel_id'):
        if c.get('cf_dns_id'):
            cf(c, f"/zones/{c['cf_zone']}/dns_records/{c['cf_dns_id']}", method='DELETE')
            c.pop('cf_dns_id')
            save(c)
        if owned('xiazt-cf'):
            run('docker', 'rm', '-f', 'xiazt-cf', capture=True)
        cf(c, f"/accounts/{c['cf_account']}/cfd_tunnel/{c['cf_tunnel_id']}/connections", method='DELETE')
        cf(c, f"/accounts/{c['cf_account']}/cfd_tunnel/{c['cf_tunnel_id']}", method='DELETE')
        c.pop('cf_tunnel_id')
        save(c)
    run('systemctl', 'disable', '--now', 'xiazt-sub.service', check=False)
    for name in NAMES:
        if owned(name):
            run('docker', 'rm', '-f', name, capture=True)
    unit = Path('/etc/systemd/system/xiazt-sub.service')
    unit.unlink(missing_ok=True)
    shortcut = Path('/usr/local/bin/x')
    if shortcut.exists() and '/opt/xiazt/manager.py' in shortcut.read_text():
        shortcut.unlink()
    if ROOT.is_symlink() or ROOT.resolve() != Path('/opt/xiazt'):
        raise RuntimeError('目录校验失败，拒绝删除')
    shutil.rmtree(ROOT)
    run('systemctl', 'daemon-reload')
    print('本脚本创建的节点与 CF 资源已删除。Docker 和其他应用保留。')


def interaction_error(exc):
    if isinstance(exc, KeyboardInterrupt):
        print('\n已取消当前操作，返回菜单。')
    elif isinstance(exc, (urllib.error.URLError, urllib.error.HTTPError)):
        print('网络请求失败：' + type(exc).__name__ + '；请检查网络或 API 权限，已返回菜单。')
    else:
        print('操作未完成：' + str(exc) + '；已返回菜单。')


def menu():
    while STATE.exists():
        try:
            _menu_loop()
            return
        except EOFError:
            return
        except (Exception, KeyboardInterrupt) as exc:
            interaction_error(exc)


def installation_menu():
    # Keep the domain as the first configuration prompt on a new machine.
    while True:
        try:
            install()
            return
        except EOFError:
            return
        except (Exception, KeyboardInterrupt) as exc:
            interaction_error(exc)
        if STATE.exists():
            menu()
            return
        while True:
            try:
                print('\n安装菜单\n1 重新配置并安装\n0 退出')
                choice = ask('选择：', '0')
                if choice == '0':
                    return
                if choice == '1':
                    break
                print('输入错误：请选择 0 或 1。')
            except EOFError:
                return
            except KeyboardInterrupt:
                print('\n已取消输入；选择 0 可退出。')


def _menu_loop():
    while True:
        print('\n瞎折腾一键脚本\n1 查看账号/订阅\n2 添加外部订阅\n3 清空外部订阅\n4 状态与日志\n5 检查/恢复节点\n6 重启服务\n7 自定义订阅名称\n9 一键卸载全部节点\n0 退出')
        choice = ask('选择：', '0')
        if choice == '0':
            return
        c = load()
        if choice == '1':
            show(c)
        elif choice == '2':
            if len(c['sources']) >= 20:
                print('最多整合 20 个外部订阅')
                continue
            url = ask('输入 HTTPS 订阅地址（输入不写入日志）：')
            nodes = fetch_source(url)
            if url not in c['sources']:
                c['sources'].append(url)
            save(c)
            refresh_sources(c)
            run('systemctl', 'restart', 'xiazt-sub')
            print(f'已添加并验证 {len(nodes)} 条链接，后台每 5 分钟刷新')
        elif choice == '3':
            c['sources'] = []
            save(c)
            write(ROOT / 'cache.json', '{}')
            run('systemctl', 'restart', 'xiazt-sub')
        elif choice == '4':
            for n in NAMES:
                if owned(n):
                    print(n, run('docker', 'inspect', '--format', '{{.State.Status}}', n, capture=True))
            run('systemctl', 'status', '--no-pager', 'xiazt-sub', check=False)
            print('详细日志：docker logs xiazt-panel / docker logs xiazt-edge / docker logs xiazt-cf')
        elif choice == '5':
            resume(c)
        elif choice == '6':
            for n in NAMES:
                if owned(n):
                    run('docker', 'restart', n, capture=True)
            run('systemctl', 'restart', 'xiazt-sub')
            c['complete'] = verify_public(c)
            save(c)
        elif choice == '7':
            current = c.get('subscription_name', DEFAULT_SUB_NAME)
            value = ask(f'自定义订阅名称 [{current}]：', current)
            try:
                c['subscription_name'] = subscription_name(value)
            except ValueError as exc:
                print(str(exc))
                continue
            save(c)
            print('已更新订阅名称：' + c['subscription_name'] + '。在客户端更新订阅即可生效。')
        elif choice == '9':
            remove()
            if not STATE.exists():
                return
        else:
            print('输入错误：请选择菜单中的编号。')


def main():
    if len(sys.argv) > 1 and sys.argv[1] == 'serve':
        serve()
        return
    if os.geteuid() != 0:
        raise RuntimeError('请用 root 或 sudo 运行')
    import fcntl
    lock_fd = os.open('/run/lock/xiazt.lock', os.O_CREAT | os.O_RDWR, 0o600)
    try:
        fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        raise RuntimeError('另一个瞎折腾管理任务正在运行，请先退出它')
    os.umask(0o077)
    print(BANNER)

    print('GitHub   https://github.com/xiazheteng8\n'
          'TG       https://t.me/xiazheteng8\n'
          'YouTube  https://www.youtube.com/@xiazheteng8\n')
    if len(sys.argv) > 1 and sys.argv[1] == 'install':
        installation_menu()
    elif STATE.exists():
        menu()
    else:
        installation_menu()
    os.close(lock_fd)


if __name__ == '__main__':
    try:
        main()
    except KeyboardInterrupt:
        print('\n已中断；已有状态保留，可运行 x 管理。')
        sys.exit(130)
    except Exception as exc:
        # urllib exceptions can include credentials in URLs: report type only.
        if isinstance(exc, (urllib.error.URLError, urllib.error.HTTPError)):
            print('网络请求失败：' + type(exc).__name__ + '；请检查网络和 API 权限', file=sys.stderr)
        else:
            print('失败：' + str(exc), file=sys.stderr)
        sys.exit(1)

XIAZT_PYTHON_EOF_938715
python3 "$workdir/manager.py" "$@"
