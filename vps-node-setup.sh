#!/usr/bin/env bash
# 瞎折腾一键脚本（全功能整合版：3x-ui/Xray + Cloudflare Tunnel + Hysteria2）
# 支持系统：Debian 12/13、Ubuntu 22.04/24.04 | 架构：amd64/arm64
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
  systemd-inhibit --what=idle:sleep --who=xiazt --why='节点部署' --mode=block sleep infinity >/dev/null 2>&1 &
  awake_pid=$!
fi
setterm --blank 0 --powersave off </dev/tty 2>/dev/null || true
if ! command -v python3 >/dev/null; then
  apt-get update
  apt-get install -y python3 ca-certificates
fi
cat >"$workdir/manager.py" <<'XIAZT_PYTHON_EOF_938715'
#!/usr/bin/env python3
import base64
import http.client
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
import urllib.parse
import urllib.request
import uuid

ROOT = Path('/opt/xiazt')
STATE = ROOT / 'state.json'
NAMES = ['xiazt-cf', 'xiazt-edge', 'xiazt-panel']
DEFAULT_SUB_NAME = '我的订阅'
# 修复：www.microsoft.com 证书过大导致 Xray-core 8192 字节缓冲区溢出握手失败 (-1)
DEFAULT_REALITY_TARGET = 'www.apple.com'
HY_CONFIG_DIR = Path('/etc/hysteria')
HY_CONFIG_FILE = HY_CONFIG_DIR / 'config.yaml'

BANNER = r"""
╭────────────────────────────────────────────────────────╮
│                                                        │
│  ██╗  ██╗██╗ █████╗ ███████╗██╗  ██╗███████╗███╗   ██╗ │
│  ╚██╗██╔╝██║██╔══██╗╚══███╔╝██║  ██║██╔════╝████╗  ██║ │
│   ╚███╔╝ ██║███████║  ███╔╝ ███████║█████╗  ██╔██╗ ██║ │
│   ██╔██╗ ██║██╔══██║ ███╔╝  ██╔══██║██╔══╝  ██║╚██╗██║ │
│  ██╔╝ ██╗██║██║  ██║███████╗██║  ██║███████╗██║ ╚████║ │
│  ╚═╝  ╚═╝╚═╝╚═╝  ╚═╝╚══════╝╚═╝  ╚═╝╚══════╝╚═╝  ╚═══╝ │
│                                                        │
╰────────────────────────────────────────────────────────╯
"""


def run(*cmd, capture=False, check=True, input=None):
    r = subprocess.run(cmd, stdout=subprocess.PIPE if capture else None,
                       stderr=subprocess.PIPE if capture else None,
                       input=input, text=True, check=check)
    return r.stdout.strip() if capture else ''


def write(path, text, mode=0o600):
    p = Path(path)
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(text, encoding='utf-8')
    os.chmod(p, mode)


def save(c):
    ROOT.mkdir(mode=0o700, parents=True, exist_ok=True)
    write(STATE, json.dumps(c, indent=2))


def load():
    return json.loads(STATE.read_text(encoding='utf-8'))


def request(url, headers=None, data=None, method=None):
    h = {'User-Agent': 'xiazt/1.0'}
    if headers:
        h.update(headers)
    req = urllib.request.Request(url, headers=h, data=data, method=method)
    with urllib.request.urlopen(req, timeout=15) as r:
        return json.loads(r.read().decode())


def ask(prompt, default=None):
    raw = input(prompt).strip()
    return raw if raw else (default if default is not None else '')


def domain(val):
    v = val.strip().lower()
    if not re.fullmatch(r'([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}', v):
        raise ValueError('域名格式错误')
    return v


def public_ip(version):
    api = 'https://api64.ipify.org?format=json' if version == 6 else 'https://api.ipify.org?format=json'
    try:
        return request(api)['ip']
    except Exception:
        return ''


def detect_public_ip():
    v4 = public_ip(4)
    if v4:
        return v4
    v6 = public_ip(6)
    if v6:
        return v6
    raise RuntimeError('未检测到公网 IPv4 或 IPv6 地址')


def panel_credentials():
    return secrets.token_urlsafe(12), secrets.token_urlsafe(20)


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


def port_free_udp(port):
    for family, address in [(socket.AF_INET, '0.0.0.0'), (socket.AF_INET6, '::')]:
        with socket.socket(family, socket.SOCK_DGRAM) as s:
            try:
                s.bind((address, port))
            except OSError:
                return False
    return True


def choose_port(preferred):
    if port_free(preferred):
        return preferred
    while True:
        p = secrets.randbelow(30000) + 20000
        if port_free(p):
            return p


def image(tag):
    run('docker', 'pull', tag)
    return run('docker', 'image', 'inspect', '--format', '{{index .RepoDigests 0}}', tag, capture=True)


def container(name, img, args=None, ports=None, volumes=None, env=None):
    cmd = ['docker', 'run', '-d', '--name', name, '--restart', 'always', '--network', 'host']
    for e in env or []:
        cmd.extend(['-e', e])
    for v in volumes or []:
        cmd.extend(['-v', f'{v[0]}:{v[1]}'])
    cmd.append(img)
    cmd.extend(args or [])
    run(*cmd)


def owned(name):
    return run('docker', 'inspect', '--format', '{{.Config.Image}}', name, capture=True, check=False) != ''


def panel_cli(c, *args):
    name = 'xiazt-panel-init-' + secrets.token_hex(8)
    cmd = ['docker', 'run', '--rm', '--name', name, '--network', 'none',
           '--workdir', '/app', '--entrypoint', '/app/x-ui',
           '-v', f"{ROOT / 'db'}:/etc/x-ui", c['panel_image'], 'setting', *args]
    print('正在初始化 3x-ui 面板设置…', flush=True)
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
        if result.returncode != 0:
            # Docker 和 x-ui 的原始输出可能包含面板凭据。
            raise RuntimeError(f"3x-ui 面板初始化失败（退出码 {result.returncode}，镜像 {c['panel_image']}）")
    except subprocess.TimeoutExpired:
        raise RuntimeError('3x-ui 面板初始化超过 60 秒，已停止等待') from None
    finally:
        try:
            subprocess.run(['docker', 'rm', '-f', name], capture_output=True, timeout=10)
        except subprocess.TimeoutExpired:
            pass



class Panel:
    def __init__(self, c):
        self.c = c
        self.cookie = ''

    def call(self, path, payload=None):
        conn = http.client.HTTPConnection('127.0.0.1', self.c['panel_port'], timeout=10)
        h = {'Cookie': self.cookie, 'Content-Type': 'application/x-www-form-urlencoded'}
        body = urllib.parse.urlencode(payload) if payload is not None else None
        conn.request('POST' if payload is not None else 'GET', self.c['panel_path'] + path.lstrip('/'), body=body, headers=h)
        res = conn.getresponse()
        data = res.read().decode()
        for v in res.headers.get_all('Set-Cookie') or []:
            self.cookie = v.split(';')[0]
        return json.loads(data) if data else {}

    def login(self):
        r = self.call('/login', {'username': self.c['username'], 'password': self.c['password']})
        if not r.get('success'):
            raise RuntimeError('3x-ui 登录失败')

    def wait(self):
        for _ in range(60):
            try:
                self.login()
                return
            except Exception:
                time.sleep(1)
        raise RuntimeError('3x-ui 启动超时')


def cf(c, path, payload=None, method=None):
    body = json.dumps(payload).encode() if payload is not None else None
    verb = method or ('POST' if body is not None else 'GET')
    endpoint = path.split('?', 1)[0]
    status = 200
    try:
        response = request('https://api.cloudflare.com/client/v4' + path,
                           headers={'Authorization': f"Bearer {c['cf_api_token']}",
                                    'Content-Type': 'application/json'},
                           data=body, method=verb)
    except urllib.error.HTTPError as exc:
        status = exc.code
        try:
            response = json.loads(exc.read(65536))
        except ValueError:
            response = {}
    if status >= 400 or not response.get('success'):
        errors = ', '.join(str(error['code']) for error in response.get('errors', []) if 'code' in error)
        raise RuntimeError(f'Cloudflare {verb} {endpoint} 失败（HTTP {status}，API 错误码：{errors or "无"}）')
    return response


def ensure_firewall_ports(c):
    """自动放行本机防火墙端口（TCP 和 Hysteria2 UDP）"""
    ports = [c['reality_port'], c['ss_port']]
    if c.get('domain'):
        ports.extend([80, c.get('https_port', 443)])
    hy_udp_port = c.get('hy2_port') if c.get('hy2_enabled') else None

    if shutil.which('ufw'):
        try:
            status = run('ufw', 'status', capture=True, check=False)
            if 'active' in status.lower() and 'inactive' not in status.lower():
                for p in ports:
                    run('ufw', 'allow', f'{p}/tcp', check=False)
                    if p == c['ss_port']:
                        run('ufw', 'allow', f'{p}/udp', check=False)
                if hy_udp_port:
                    run('ufw', 'allow', f'{hy_udp_port}/udp', check=False)
                print(f'已在 UFW 防火墙自动放行端口：TCP {ports}' + (f'，UDP {hy_udp_port}' if hy_udp_port else ''))
        except Exception:
            pass

    if shutil.which('iptables'):
        try:
            for p in ports:
                run('iptables', '-I', 'INPUT', '-p', 'tcp', '--dport', str(p), '-j', 'ACCEPT', check=False)
                if p == c['ss_port']:
                    run('iptables', '-I', 'INPUT', '-p', 'udp', '--dport', str(p), '-j', 'ACCEPT', check=False)
            if hy_udp_port:
                run('iptables', '-I', 'INPUT', '-p', 'udp', '--dport', str(hy_udp_port), '-j', 'ACCEPT', check=False)
        except Exception:
            pass


def is_hy2_installed():
    return Path('/usr/local/bin/hysteria').exists() and HY_CONFIG_FILE.exists()


def install_hy2_auto(c):
    """域名部署时自动配置并安装 Hysteria 2（复用已有的域名和 Cloudflare API Token，无需重复输入）"""
    domain_name = c.get('hy2_hostname')
    token = c.get('cf_api_token')
    if not domain_name or not token:
        c['hy2_enabled'] = False
        return

    print('\n正在检测并自动部署 Hysteria 2 (高速 UDP 协议)...')
    port = 24443
    while port == c['ss_port'] or not port_free_udp(port):
        port = secrets.randbelow(30000) + 20000

    run('apt-get', 'update')
    run('apt-get', 'install', '-y', 'curl', 'ca-certificates')

    installer = run('mktemp', capture=True)
    try:
        run('curl', '-fsSL', '--retry', '3', 'https://get.hy2.sh/', '-o', installer)
        run('bash', installer)
    finally:
        if Path(installer).exists():
            Path(installer).unlink()

    password = c.get('hy2_password') or secrets.token_urlsafe(32)
    config = {
        "listen": f":{port}",
        "acme": {
            "domains": [domain_name],
            "type": "dns",
            "dns": {
                "name": "cloudflare",
                "config": {
                    "cloudflare_api_token": token.strip()
                }
            }
        },
        "auth": {
            "type": "password",
            "password": password
        },
        "masquerade": {
            "type": "proxy",
            "proxy": {
                "url": "https://www.cloudflare.com",
                "rewriteHost": True
            }
        }
    }

    HY_CONFIG_DIR.mkdir(parents=True, exist_ok=True, mode=0o750)
    write(HY_CONFIG_FILE, json.dumps(config, indent=2) + "\n", 0o640)

    try:
        shutil.chown(HY_CONFIG_FILE, user='root', group='hysteria')
    except Exception:
        pass

    run('systemctl', 'daemon-reload')
    run('systemctl', 'enable', 'hysteria-server')
    run('systemctl', 'restart', 'hysteria-server')
    run('systemctl', 'is-active', '--quiet', 'hysteria-server')

    c.update(hy2_enabled=True, hy2_domain=domain_name, hy2_port=port, hy2_password=password)
    ensure_firewall_ports(c)
    save(c)

    print(f'\n✅ Hysteria 2 已自动部署完成，监听 UDP {port}，节点已自动汇入订阅。')


def resolve_cf_identity(c):
    zones = cf(c, '/zones')['result']
    matches = [z for z in zones if c['cf_hostname'] == z['name']
               or c['cf_hostname'].endswith('.' + z['name'])]
    if not matches:
        raise RuntimeError('Token 无法访问该域名的 Zone')
    zone = max(matches, key=lambda z: len(z['name']))
    c['cf_zone'] = zone['id']
    c['cf_account'] = zone['account']['id']


def setup_cf(c):
    if c['tunnel'] != 'fixed':
        return
    resolve_cf_identity(c)
    host = c['cf_hostname']
    account = f"/accounts/{c['cf_account']}/cfd_tunnel"
    records = f"/zones/{c['cf_zone']}/dns_records"
    lookup = records + '?' + urllib.parse.urlencode({'name.exact': host})
    existing = cf(c, lookup)['result']
    tunnel_id = c.get('cf_tunnel_id')
    if not tunnel_id:
        tunnel_name = f"xiazt-{c['short_id']}"
        params = urllib.parse.urlencode({'name': tunnel_name, 'is_deleted': 'false'})
        matches = [t for t in cf(c, account + '?' + params)['result'] if t['name'] == tunnel_name]
        if len(matches) > 1:
            raise RuntimeError(f'发现多个同名隧道：{tunnel_name}')
        if matches:
            tunnel_id = matches[0]['id']
        elif existing:
            raise RuntimeError(f'{host} 已有 DNS 记录，请使用空闲子域名')
        else:
            tunnel_id = cf(c, account, {
                'name': tunnel_name,
                'config_src': 'cloudflare',
                'tunnel_secret': base64.b64encode(secrets.token_bytes(32)).decode(),
            })['result']['id']
        c['cf_tunnel_id'] = tunnel_id
        c.pop('cf_tunnel_token', None)
        save(c)
    target = f'{tunnel_id}.cfargotunnel.com'
    if any(r['type'] != 'CNAME' or r['content'].rstrip('.') != target for r in existing):
        raise RuntimeError(f'{host} 的 DNS 记录与脚本隧道不匹配，现有记录未改动')
    if not c.get('cf_tunnel_token'):
        info = cf(c, f'{account}/{tunnel_id}/token')['result']
        token = info if isinstance(info, str) else info.get('token')
        if not token:
            raise RuntimeError('Cloudflare 未返回隧道运行凭据')
        c['cf_tunnel_token'] = token
        save(c)
    route = {'hostname': host, 'service': f"http://127.0.0.1:{c['edge_port']}"}
    config_path = f'{account}/{tunnel_id}/configurations'
    cf(c, config_path, {'config': {'ingress': [route, {'service': 'http_status:404'}]}}, method='PUT')
    config = cf(c, config_path)['result']['config']
    if not any(all(rule.get(k) == v for k, v in route.items()) for rule in config.get('ingress', [])):
        raise RuntimeError(f'Cloudflare 未保存 {host} 的隧道路由')
    print(f'Cloudflare 隧道路由已确认：{host} → {route["service"]}', flush=True)

    payload = {'type': 'CNAME', 'name': host, 'content': target, 'proxied': True}
    if not existing:
        cf(c, records, payload)
    elif not existing[0].get('proxied'):
        cf(c, f"{records}/{existing[0]['id']}", {'proxied': True}, method='PATCH')
    confirmed = [r for r in cf(c, lookup)['result']
                 if r['type'] == 'CNAME' and r['content'].rstrip('.') == target and r.get('proxied')]
    if not confirmed:
        raise RuntimeError(f'Cloudflare 未保存 {host} 的橙云 CNAME')
    c['cf_dns_id'] = confirmed[0]['id']
    save(c)
    print(f'Cloudflare 橙云 CNAME 已确认：{host}', flush=True)


def setup_nodes(c):
    p = Panel(c)
    p.login()
    def checked(path, payload=None):
        result = p.call(path, payload)
        if not result.get('success'):
            raise RuntimeError(f'3x-ui API {path}: {result.get("msg") or "操作失败"}')
        return result.get('obj')

    managed_ports = {c[key + '_port'] for key in ('reality', 'ss', 'vless', 'vmess', 'trojan')}
    for row in checked('/panel/api/inbounds/list') or []:
        if row['port'] in managed_ports:
            checked(f"/panel/api/inbounds/del/{row['id']}", {})

    def add(remark, port, protocol, settings, stream):
        checked('/panel/api/inbounds/add', {'up': 0, 'down': 0, 'total': 0, 'remark': remark, 'enable': 'true',
                                           'expiryTime': 0, 'listen': '127.0.0.1' if stream.get('network') == 'ws' else '',
                                           'port': port, 'protocol': protocol,
                                           'settings': json.dumps(settings), 'streamSettings': json.dumps(stream)})

    ws = lambda path: {'network': 'ws', 'security': 'none', 'wsSettings': {'path': path}}
    # 修复：新版 Xray-core 在 REALITY 中强制要求 minClientVer，否则所有客户端直接拒绝握手显示 -1
    reality = {'network': 'tcp', 'security': 'reality',
               'realitySettings': {'show': False, 'dest': f"{c['sni']}:443", 'xver': 0,
                                   'serverNames': [c['sni']], 'privateKey': c['private_key'],
                                   'minClientVer': '1.0.0',
                                   'shortIds': [c['short_id']]}}
    add('REALITY', c['reality_port'], 'vless',
        {'clients': [{'id': c['uuid'], 'flow': 'xtls-rprx-vision'}], 'decryption': 'none'}, reality)
    add('SS', c['ss_port'], 'shadowsocks',
        {'method': 'chacha20-ietf-poly1305', 'password': c['node_password'], 'network': 'tcp,udp'},
        {'network': 'tcp', 'security': 'none'})
    for proto in ('vless', 'vmess', 'trojan'):
        field = 'id' if proto in ('vless', 'vmess') else 'password'
        cred = c['uuid'] if proto in ('vless', 'vmess') else c['node_password']
        extra = {'decryption': 'none'} if proto == 'vless' else {}
        add(proto.upper(), c[proto + '_port'], proto,
            {'clients': [{field: cred}], **extra}, ws(f"{c['ws_prefix']}/{proto}"))
    ensure_firewall_ports(c)


def b64(s):
    return base64.urlsafe_b64encode(s.encode() if isinstance(s, str) else s).decode().rstrip('=')


def subscription_name(val):
    v = val.strip()
    if not v:
        return DEFAULT_SUB_NAME
    if any(ch in v for ch in '\r\n\t#/?'):
        raise ValueError('订阅名称不能包含换行、#、/ 或 ? 等特殊字符')
    return v


def link(proto, cred, host, port, query, fragment):
    return f"{proto}://{cred}@{host}:{port}?" + urllib.parse.urlencode(query) + '#' + urllib.parse.quote(fragment)


def quick_host():
    if not owned('xiazt-cf'):
        return ''
    for _ in range(60):
        logs = run('docker', 'logs', '--tail', '100', 'xiazt-cf', capture=True, check=False)
        m = re.findall(r'https://([a-z0-9-]+\.trycloudflare\.com)', logs)
        if m:
            return m[-1]
        time.sleep(1)
    return ''


def endpoints(c):
    if c['tunnel'] == 'fixed':
        return [c['cf_hostname']]
    if c['tunnel'] == 'quick':
        h = quick_host()
        return [h] if h else []
    return [c['domain']] if c['domain'] else []


def endpoint_port(c, host):
    if host == c['domain'] and c['tunnel'] == 'none':
        return c.get('https_port', 443)
    return 443


def subscription_url(c, host):
    port = endpoint_port(c, host)
    authority = host if port == 443 else f'{host}:{port}'
    return f"https://{authority}/sub/{c['sub_token']}"


def node_links(c, name=None):
    name = subscription_name(c.get('subscription_name', DEFAULT_SUB_NAME) if name is None else name)
    ip_host = '[' + c['ip'] + ']' if ':' in c['ip'] else c['ip']
    links = [link('vless', c['uuid'], ip_host, c['reality_port'],
                  {'encryption': 'none', 'security': 'reality', 'sni': c['sni'],
                   'fp': 'chrome', 'pbk': c['public_key'], 'sid': c['short_id'],
                   'type': 'tcp', 'flow': 'xtls-rprx-vision', 'spx': '/'}, name + '-REALITY')]
    links.append('ss://' + b64('chacha20-ietf-poly1305:' + c['node_password']) +
                 f"@{ip_host}:{c['ss_port']}#" + urllib.parse.quote(name + '-SS'))
    for host in endpoints(c):
        port = endpoint_port(c, host)
        for proto in ('vless', 'trojan'):
            q = {'security': 'tls', 'sni': host, 'type': 'ws', 'host': host,
                 'path': c['ws_prefix'] + '/' + proto}
            if proto == 'vless':
                q['encryption'] = 'none'
            links.append(link(proto, c['uuid'] if proto == 'vless' else c['node_password'],
                              host, port, q, name + '-' + proto + '-' + host))
        links.append('vmess://' + b64(json.dumps({'v': '2', 'ps': name + '-vmess-' + host,
            'add': host, 'port': port, 'id': c['uuid'], 'aid': 0, 'scy': 'auto',
            'net': 'ws', 'type': 'none', 'host': host, 'path': c['ws_prefix'] + '/vmess',
            'tls': 'tls', 'sni': host}, ensure_ascii=False)))
    if c.get('hy2_enabled') and c.get('hy2_domain') and c.get('hy2_port'):
        hy_name = urllib.parse.quote(name + '-Hysteria2')
        links.append(f"hysteria2://{c['hy2_password']}@{c['hy2_domain']}:{c['hy2_port']}/?sni={c['hy2_domain']}#{hy_name}")
    return links


def subscription_response(c, name=None):
    merged = list(node_links(c, name=name))
    cache = ROOT / 'cache.json'
    if cache.exists():
        for source, nodes in json.loads(cache.read_text()).items():
            merged.extend(nodes)
    return base64.b64encode('\n'.join(dict.fromkeys(merged)).encode()).decode()


def parse_subscription(text):
    nodes = []
    for line in text.splitlines():
        line = line.strip()
        if not line:
            continue
        if any(line.startswith(p) for p in
               ('vless://', 'vmess://', 'trojan://', 'ss://', 'ssr://',
                'hysteria2://', 'hy2://', 'tuic://', 'hysteria://')):
            nodes.append(line)
    return nodes


def redirect_request(req, fp, code, msg, headers, newurl):
    m = req.get_method()
    if code in (301, 302, 303, 307, 308) and m in ('GET', 'HEAD'):
        newurl = newurl.replace(' ', '%20')
        CONTENT_HEADERS = ('content-length', 'content-type')
        newheaders = {k: v for k, v in req.headers.items() if k.lower() not in CONTENT_HEADERS}
        return urllib.request.Request(newurl, headers=newheaders, origin_req_host=req.origin_req_host,
                                      unverifiable=True, method=m)
    raise urllib.error.HTTPError(req.full_url, code, msg, headers, fp)


class SafeRedirectHandler(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return redirect_request(req, fp, code, msg, headers, newurl)


class StrictHTTPSRedirectHandler(SafeRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        if urllib.parse.urlsplit(newurl).scheme != 'https':
            raise urllib.error.HTTPError(req.full_url, code, '拒绝非 HTTPS 重定向', headers, fp)
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def validate_source(url):
    u = urllib.parse.urlsplit(url)
    if u.scheme != 'https':
        raise ValueError('仅支持 HTTPS 订阅链接')
    ip = socket.gethostbyname(u.hostname)
    if any([ip.startswith('127.'), ip.startswith('10.'), ip.startswith('192.168.'),
            ip.startswith('169.254.'), re.match(r'^172\.(1[6-9]|2[0-9]|3[0-1])\.', ip)]):
        raise ValueError('禁止订阅私有内网地址')


def fetch_source(url):
    validate_source(url)
    opener = urllib.request.build_opener(StrictHTTPSRedirectHandler())
    req = urllib.request.Request(url, headers={'User-Agent': 'v2rayN/6.23'})
    with opener.open(req, timeout=10) as r:
        raw = r.read(1048576)
    nodes = parse_subscription(raw.decode('utf-8', 'ignore'))
    if not nodes:
        encoded = b''.join(raw.split())
        try:
            decoded = base64.b64decode(encoded + b'=' * (-len(encoded) % 4),
                                       altchars=b'-_', validate=True)
            nodes = parse_subscription(decoded.decode('utf-8'))
        except (ValueError, UnicodeError):
            nodes = []
    if not nodes:
        raise ValueError('未解析出任何有效代理节点')
    return nodes


def refresh_sources(c):
    cache = {}
    for url in c.get('sources', []):
        try:
            cache[url] = fetch_source(url)
        except Exception:
            continue
    write(ROOT / 'cache.json', json.dumps(cache))


def fetch(c):
    if not c.get('sources'):
        return
    for _ in range(3):
        try:
            refresh_sources(c)
            return
        except Exception:
            time.sleep(10)


def serve():
    c = load()
    token = c['sub_token']
    threading.Thread(target=worker, args=(c,), daemon=True).start()
    from http.server import HTTPServer, BaseHTTPRequestHandler

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, fmt, *args):
            return

        def do_GET(self):
            raw_path = self.path.split('?', 1)[0].rstrip('/')
            match = re.fullmatch(r'/sub/([^/]+)(?:/([^/]+))?', raw_path)
            if not match or match.group(1) != token:
                self.send_response(404)
                self.end_headers()
                return
            custom_name = urllib.parse.unquote(match.group(2)) if match.group(2) else None
            try:
                body = subscription_response(load(), name=custom_name)
            except ValueError:
                self.send_response(400)
                self.end_headers()
                self.wfile.write(b'Invalid custom subscription name')
                return
            self.send_response(200)
            self.send_header('Content-Type', 'text/plain; charset=utf-8')
            self.send_header('Profile-Update-Interval', '6')
            self.end_headers()
            self.wfile.write(body.encode())

    server = HTTPServer(('127.0.0.1', c['sub_port']), Handler)
    server.serve_forever()


def worker(c):
    while True:
        try:
            fetch(c)
        except Exception:
            pass
        time.sleep(300)


def caddy_config(c):
    routes = ''
    for proto in ('vless', 'vmess', 'trojan'):
        routes += f"    handle {c['ws_prefix']}/{proto}* {{\n        reverse_proxy 127.0.0.1:{c[proto + '_port']}\n    }}\n"
    routes += f"    handle /sub/* {{\n        reverse_proxy 127.0.0.1:{c['sub_port']}\n    }}\n    handle /health {{\n        respond ok\n    }}\n    handle {{\n        respond 404\n    }}\n"
    # 修复：禁用 Caddy 默认开启的 HTTP/3 (QUIC)，防止与 Hysteria 2 在 UDP 443 发生端口冲突
    config = '{\n    admin off\n    servers {\n        protocols h1 h2\n    }\n'
    if c.get('https_port') or not c.get('http_challenge', True):
        config += '    auto_https disable_redirects\n'
    config += '}\n'
    config += f"http://:{c['edge_port']} {{\n    bind 127.0.0.1\n" + routes + '}\n'
    if c['domain'] and c.get('https_port'):
        host = c['domain']
        port = c['https_port']
        config += f'http://{host} {{\n    respond 404\n}}\n'
        tls = '    tls {\n        issuer acme {\n            disable_tlsalpn_challenge\n        }\n    }\n'
        config += f'https://{host}:{port} {{\n' + tls + routes + '}\n'
    elif c['domain']:
        tls = '' if c.get('http_challenge', True) else '    tls {\n        issuer acme {\n            disable_http_challenge\n        }\n    }\n'
        config += c['domain'] + ' {\n' + tls + routes + '}\n'
    return config


def install_services(c):
    write(ROOT / 'Caddyfile', caddy_config(c))
    if not owned('xiazt-edge'):
        container('xiazt-edge', c['edge_image'],
                  volumes=[(ROOT / 'Caddyfile', '/etc/caddy/Caddyfile'), (ROOT / 'caddy', '/data')])
    else:
        run('docker', 'restart', 'xiazt-edge')
    unit = f"""[Unit]
Description=xiazt subscription
After=network.target

[Service]
ExecStart=/usr/bin/python3 /opt/xiazt/manager.py serve
Restart=always
User=root

[Install]
WantedBy=multi-user.target
"""
    write('/etc/systemd/system/xiazt-sub.service', unit)
    run('systemctl', 'daemon-reload')
    run('systemctl', 'enable', '--now', 'xiazt-sub.service')
    run('systemctl', 'restart', 'xiazt-sub.service')
    if c['tunnel'] == 'quick':
        if not owned('xiazt-cf'):
            container('xiazt-cf', c['cf_image'], args=['tunnel', '--url', f"http://127.0.0.1:{c['edge_port']}"])
        else:
            run('docker', 'restart', 'xiazt-cf')
    elif c['tunnel'] == 'fixed':
        setup_cf(c)
        args = ['tunnel', 'run', '--token', c['cf_tunnel_token']]
        if owned('xiazt-cf'):
            current = run('docker', 'inspect', '--format', '{{json .Config.Cmd}}', 'xiazt-cf', capture=True)
            if json.loads(current) == args:
                run('docker', 'restart', 'xiazt-cf')
                return
            run('docker', 'rm', '-f', 'xiazt-cf', capture=True)
        container('xiazt-cf', c['cf_image'], args=args)


def verify_public(c):
    hosts = endpoints(c)
    if not hosts:
        print('未找到公网订阅域名。')
        return False
    expected = set(node_links(c))
    opener = urllib.request.build_opener(StrictHTTPSRedirectHandler())
    deadline = time.monotonic() + 150
    failure = ''
    print(f'正在检查 HTTPS 订阅：{hosts[0]}（最多约 150 秒）', flush=True)
    while time.monotonic() < deadline:
        for host in hosts:
            try:
                req = urllib.request.Request(subscription_url(c, host),
                                             headers={'User-Agent': 'xiazt-verify/1.0'})
                with opener.open(req, timeout=5) as response:
                    payload = response.read(2 * 1024 * 1024)
                    actual = set(parse_subscription(base64.b64decode(payload, validate=True).decode('utf-8')))
                    if response.status == 200 and expected and expected.issubset(actual):
                        return True
                failure = '订阅内容缺少预期节点'
            except urllib.error.HTTPError as exc:
                failure = f'HTTP {exc.code}'
            except urllib.error.URLError as exc:
                failure = str(exc.reason)
            except ValueError:
                failure = '响应无法解码为节点订阅'
            except OSError as exc:
                failure = type(exc).__name__
        time.sleep(2)
    print(f'公网订阅检查失败：{hosts[0]}（{failure}）')
    return False


def show(c):
    print('订阅名称：' + c.get('subscription_name', DEFAULT_SUB_NAME))
    print('\n3x-ui 后台通过 SSH 转发访问：')
    sshhost = '[' + c['ip'] + ']' if ':' in c['ip'] else c['ip']
    print(f"ssh -N -L {c['panel_port']}:127.0.0.1:{c['panel_port']} root@{sshhost}")
    print(f"3x-ui 后台：http://127.0.0.1:{c['panel_port']}{c['panel_path']}")
    print('3x-ui 后台账号：' + c['username'] + '\n3x-ui 后台密码：' + c['password'])
    if c.get('complete'):
        for host in endpoints(c):
            print('订阅：' + subscription_url(c, host))
    else:
        print('订阅尚未通过公网验证，请运行 x → 检查/恢复。')
    print(f"需放行：TCP {c['reality_port']}；TCP/UDP {c['ss_port']}" +
          (f"；TCP 80/{c.get('https_port', 443)}（域名直连）" if c['domain'] else ''))
    print('WS 源站、后台、订阅源站只监听本机。云安全组需手动放行上述端口。')
    if c['tunnel'] == 'quick':
        print('临时隧道重启会换域名：运行 x 查看新订阅。节点订阅内容会自动使用当前域名。')
    if c.get('hy2_enabled') and c.get('hy2_domain'):
        hy_name = urllib.parse.quote(c.get('subscription_name', DEFAULT_SUB_NAME) + '-Hysteria2')
        print(f"\nHysteria2 节点：hysteria2://{c['hy2_password']}@{c['hy2_domain']}:{c['hy2_port']}/?sni={c['hy2_domain']}#{hy_name}")
        print(f"Hysteria2 端口：UDP {c['hy2_port']}（云安全组需放行该 UDP 端口）")
    print('快捷管理：x；凭据保存：/opt/xiazt/state.json（root 专用）')
    print('\n【节点连通性排查指南】')
    print('1. REALITY / SS 直连节点：若测速显示 -1，请务必在云服务器服务商（如 AWS / 阿里云 / 腾讯云 / 甲骨文）的安全组后台添加入站规则，放行 TCP ' + str(c['reality_port']) + ' 和 TCP/UDP ' + str(c['ss_port']) + '。')
    if c.get('hy2_enabled'):
        print('2. Hysteria 2 节点：需在云服务器安全组放行 UDP ' + str(c['hy2_port']) + '，且 Cloudflare 上的 A 记录必须为【仅 DNS/灰色云朵】。')
    if c['tunnel'] == 'quick':
        print('3. 临时隧道说明：Cloudflare 临时域名 (*.trycloudflare.com) 在中国境内已被 GFW 阻断 SNI / DNS 污染，国内客户端测试临时隧道节点显示 -1 属正常现象。请在境内优先使用 REALITY / Hysteria2 节点，或改用 [固定隧道] 并绑定自己的域名！')


def install():
    if STATE.exists():
        raise RuntimeError('已有专用实例，请使用 x 管理或先卸载；拒绝覆盖现有凭据')
    if ROOT.exists() and any(ROOT.iterdir()):
        raise RuntimeError('/opt/xiazt 已存在且非空，拒绝覆盖')
    if Path('/usr/local/bin/x').exists():
        raise RuntimeError('/usr/local/bin/x 已存在，拒绝覆盖已有快捷命令')
    for n in NAMES:
        if shutil.which('docker') and run('docker', 'inspect', '--format', '{{.Id}}', n, capture=True, check=False):
            raise RuntimeError(f'容器名 {n} 已存在，拒绝覆盖')
    tunnel = ask('CF 隧道：1 临时 / 2 固定（推荐）[2]：', '2')
    if tunnel not in ('1', '2'):
        raise ValueError('隧道选项必须是 1 或 2')
    ip = detect_public_ip()
    sni = DEFAULT_REALITY_TARGET
    print('自动识别 VPS 公网 IP：' + ip)
    print('REALITY 目标域名自动设置为：' + sni)
    username, password = panel_credentials()
    custom_name = subscription_name(ask('自定义订阅名称 [我的订阅]：', DEFAULT_SUB_NAME))
    c = {'domain': '', 'ip': ip, 'tunnel': {'1': 'quick', '2': 'fixed'}[tunnel],
         'username': username, 'password': password, 'panel_path': '/' + secrets.token_hex(12) + '/',
         'uuid': str(uuid.uuid4()), 'node_password': secrets.token_urlsafe(24),
         'sub_token': secrets.token_urlsafe(32), 'short_id': secrets.token_hex(8),
         'sni': sni, 'ws_prefix': '/' + secrets.token_hex(12), 'sources': [], 'complete': False,
         'subscription_name': custom_name}
    if tunnel == '2':
        c['cf_hostname'] = domain(ask('固定隧道域名（CF 托管的空闲子域名）：'))
        c['cf_api_token'] = ask('Cloudflare API Token（Tunnel Edit / DNS Edit / Zone Read）：').strip()
        if not c['cf_api_token']:
            raise ValueError('API Token 不能为空')
        resolve_cf_identity(c)
        print('已自动识别 Cloudflare 域名区域及所属账户。')
    if c.get('cf_api_token'):
        hy2_hostname = ask('Hysteria 2 灰云域名（指向本 VPS，回车跳过）：')
        if hy2_hostname:
            c['hy2_hostname'] = domain(hy2_hostname)
            if c['hy2_hostname'] == c.get('cf_hostname'):
                raise ValueError('Hysteria 2 请使用独立的灰云域名')
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
    
    pkgs = ['ca-certificates', 'curl', 'openssl']
    if not shutil.which('docker'):
        pkgs.append('docker.io')
        
    run('apt-get', 'install', '-y', *pkgs)
    run('systemctl', 'enable', '--now', 'docker')
    release = request('https://api.github.com/repos/MHSanaei/3x-ui/releases/latest')['tag_name']
    c['panel_version'] = release
    c['panel_image'] = image('ghcr.io/mhsanaei/3x-ui:' + release)
    c['edge_image'] = image('caddy:2')
    c['cf_image'] = image('cloudflare/cloudflared:latest')
    ROOT.mkdir(mode=0o700, parents=True, exist_ok=True)
    (ROOT / 'db').mkdir(mode=0o700)
    save(c)
    shutil.copyfile(Path(__file__), ROOT / 'manager.py')
    os.chmod(ROOT / 'manager.py', 0o700)
    write('/usr/local/bin/x', '#!/bin/sh\nexec /usr/bin/python3 /opt/xiazt/manager.py "$@"\n', 0o755)

    resume(c)


def resume(c):
    c['complete'] = False
    save(c)
    if not owned('xiazt-panel'):
        panel_cli(c, '-username', c['username'], '-password', c['password'],
                  '-port', str(c['panel_port']), '-listenIP', '127.0.0.1', '-webBasePath', c['panel_path'])
        with sqlite3.connect(ROOT / 'db/x-ui.db') as db:
            for key, value in [('subEnable', 'false'), ('subListen', '127.0.0.1')]:
                db.execute('DELETE FROM settings WHERE key = ?', (key,))
                db.execute('INSERT INTO settings (key, value) VALUES (?, ?)', (key, value))
        container('xiazt-panel', c['panel_image'], volumes=[(ROOT / 'db', '/etc/x-ui')],
                  env=['XUI_ENABLE_FAIL2BAN=false', 'TZ=Asia/Shanghai'])
    else:
        run('docker', 'start', 'xiazt-panel', capture=True)
    Panel(c).wait()
    if not c.get('private_key'):
        key = subprocess.check_output(['openssl', 'genpkey', '-algorithm', 'X25519'])
        private = subprocess.check_output(['openssl', 'pkey', '-outform', 'DER'], input=key)[-32:]
        public = subprocess.check_output(['openssl', 'pkey', '-pubout', '-outform', 'DER'], input=key)[-32:]
        c['private_key'] = base64.urlsafe_b64encode(private).decode().rstrip('=')
        c['public_key'] = base64.urlsafe_b64encode(public).decode().rstrip('=')
        save(c)
    setup_nodes(c)
    install_services(c)
    if c.get('hy2_hostname'):
        if not c.get('hy2_enabled') or not is_hy2_installed():
            install_hy2_auto(c)
        else:
            run('systemctl', 'restart', 'hysteria-server')
        run('systemctl', 'is-active', '--quiet', 'hysteria-server')
    c['complete'] = verify_public(c)
    save(c)
    if not c['complete']:
        raise RuntimeError('部署未通过公网订阅检查，运行 x → 检查/恢复')
    show(c)
    print('服务与 HTTPS 订阅检查通过。真实代理通断仍需从客户端测试。')


def remove():
    c = load()
    if ask('删除本脚本全部节点、后台、凭据和订阅；输入 DELETE 确认：') != 'DELETE':
        return
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
    if c.get('hy2_enabled'):
        run('systemctl', 'disable', '--now', 'hysteria-server', check=False)
        if HY_CONFIG_FILE.exists():
            HY_CONFIG_FILE.unlink(missing_ok=True)
    unit = Path('/etc/systemd/system/xiazt-sub.service')
    unit.unlink(missing_ok=True)
    shortcut = Path('/usr/local/bin/x')
    if shortcut.exists() and '/opt/xiazt/manager.py' in shortcut.read_text():
        shortcut.unlink()
    if ROOT.is_symlink() or ROOT.resolve() != Path('/opt/xiazt'):
        raise RuntimeError('目录校验失败，拒绝删除')
    shutil.rmtree(ROOT)
    run('systemctl', 'daemon-reload')
    print('本脚本创建的节点、Hysteria2 与 CF 资源已删除。Docker 和其他应用保留。')


def interaction_error(exc):
    if isinstance(exc, KeyboardInterrupt):
        print('\n已取消输入。')
    else:
        print(f"\n错误：{exc}")


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
            if c.get('hy2_enabled'):
                print('hysteria-server', run('systemctl', 'is-active', 'hysteria-server', capture=True, check=False))
            print('详细日志：docker logs xiazt-panel / docker logs xiazt-edge / docker logs xiazt-cf / journalctl -u hysteria-server')
        elif choice == '5':
            resume(c)
        elif choice == '6':
            for n in NAMES:
                if owned(n):
                    run('docker', 'restart', n, capture=True)
            run('systemctl', 'restart', 'xiazt-sub')
            if c.get('hy2_enabled') and is_hy2_installed():
                run('systemctl', 'restart', 'hysteria-server', check=False)
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
    if len(sys.argv) > 1 and sys.argv[1] == 'update':
        if not STATE.exists():
            raise RuntimeError('找不到现有部署，首次安装请直接运行脚本')
        write(ROOT / 'manager.py', Path(__file__).read_text(encoding='utf-8'), 0o700)
        resume(load())
    elif len(sys.argv) > 1 and sys.argv[1] == 'install':
        installation_menu()
    elif STATE.exists():
        menu()
    else:
        installation_menu()
    os.close(lock_fd)


if __name__ == '__main__':
    main()
XIAZT_PYTHON_EOF_938715
python3 "$workdir/manager.py" "$@"
