# 瞎折腾节点管理器

在 Debian 或 Ubuntu VPS 上部署独立的 3x-ui / Xray、Caddy 和 HTTPS 订阅服务。脚本支持 Cloudflare 临时与固定隧道，可把 Hysteria 2（H2）和其他节点放入同一个订阅。安装后运行 `sudo x` 进行管理。

## 选择脚本

| 文件 | 部署方式 | VPS 入站 TCP 443 |
| --- | --- | --- |
| [`xiazt-fixed.sh`](./xiazt-fixed.sh) | 常规版，支持自有域名直连、Cloudflare 临时隧道和固定隧道 | 填写直连域名时需要。仅使用隧道时无需开放 |
| [`xiazt-no443.sh`](./xiazt-no443.sh) | 免入站 443 版，使用 Cloudflare 临时或固定隧道提供 HTTPS 订阅和 WebSocket | 无需开放 |

免入站 443 版仍需要 VPS 能访问软件源、镜像仓库和 Cloudflare。Hysteria 2 使用独立的公网 UDP 端口。

## 安装

- 系统支持 Debian 12 / 13、Ubuntu 22.04 / 24.04，架构支持 amd64 / arm64。
- 通过 SSH 交互式终端运行，需要 root 或 sudo 权限，系统须运行 systemd。
- 下载脚本后执行。以下命令适用于脚本已上传到仓库 `main` 分支根目录的情况。已将脚本上传到 VPS 时，直接执行对应的 `sudo bash` 命令即可。

### 常规版

```bash
curl -fLO https://raw.githubusercontent.com/xiazheteng8/xiazheteng-node-manager/main/xiazt-fixed.sh &&
  sudo bash xiazt-fixed.sh
```
### 常规(ip)端口放行原生订阅版

```bash
curl -fLO https://raw.githubusercontent.com/xiazheteng8/xiazheteng-node-manager/main/xiazt-panel-public-ip.sh &&
  sudo bash xiazt-panel-public-ip.sh
```
### 免入站 443 版

```bash
curl -fLO https://raw.githubusercontent.com/xiazheteng8/xiazheteng-node-manager/main/xiazt-no443.sh &&
  sudo bash xiazt-no443.sh
```
### 免入站 443（ip）端口放行原生订阅版

```bash
curl -fLO https://raw.githubusercontent.com/xiazheteng8/xiazheteng-node-manager/main/xiazt-tunnel-panel-public-ip.sh &&
  sudo bash xiazt-tunnel-panel-public-ip.sh
```
## 配置入口

- **临时隧道（选项 1）**。常规版先在直连域名提示处按回车，再选 `1`。免入站 443 版直接选 `1`。Cloudflare 会分配一个 `trycloudflare.com` 地址，隧道重启后地址可能变化。运行 `sudo x` 并选 `1` 查看当前订阅。
- **固定隧道（选项 2）**。准备一个托管在 Cloudflare 的空闲子域名和 API Token。Token 需要账户的 Tunnel Edit 权限，以及目标区域的 DNS Edit、Zone Read 权限。仅使用固定隧道时，常规版在最初的直连域名提示处按回车。脚本会查询域名所属账户，并为隧道创建 DNS 记录。
- **自有域名直连（常规版选项 0）**。先将域名的 A 或 AAAA 记录指向 VPS 公网 IP。若使用 Cloudflare DNS，选择「仅 DNS」。填写该域名并选择 `0`，放行入站 TCP 443。终端会提示是否还需开放 TCP 80。

脚本会尝试检测公网 IP。结果正确时按回车确认，也可以手动输入公网 IPv4 或 IPv6。检测失败时，纯隧道模式可按回车先部署 WebSocket 节点和订阅。之后可进入 `sudo x` → `5 检查/恢复节点`，填写公网 IP 并添加直连节点。

安装过程中，耗时步骤会输出阶段进度，等待临时域名超时后会提示查看日志。

## 节点与端口

| 节点 | 连接方式 | VPS 端口 |
| --- | --- | --- |
| VLESS / VMess / Trojan WebSocket | HTTPS 域名或 Cloudflare 隧道 | 隧道模式无需单独开放 WebSocket 后端端口 |
| VLESS REALITY | 公网 IP 直连 | 默认 TCP 8443 |
| Shadowsocks | 公网 IP 直连 | 默认 TCP / UDP 18443 |
| Hysteria 2 | 公网 IP 直连 | 默认 UDP 24443 |

默认端口被占用时，脚本会选择其他端口。以安装结果或 `sudo x` → `1 查看账号/订阅` 为准，在云安全组和系统防火墙放行所需端口。Hysteria 2 配置保存在 `/opt/xiazt/h2/config.yaml`，订阅链接包含证书指纹，请使用支持 Hysteria 2 和证书指纹校验的客户端。

## 查看订阅与管理面板

```bash
sudo x
```

选择 `1 查看账号/订阅`，复制 HTTPS 订阅地址到客户端。订阅地址含访问密钥。3x-ui 面板通过 SSH 本地端口转发访问，终端会打印命令模板，替换成自己的 SSH 用户和 VPS 地址即可。

| 菜单 | 用途 |
| --- | --- |
| `1` | 查看账号、订阅、SSH 转发命令和端口 |
| `2` / `3` | 添加或清空外部 HTTPS 订阅 |
| `4` | 查看服务状态和日志提示 |
| `5` | 检查或恢复部署 |
| `6` | 重启服务并重新检查订阅 |
| `7` | 修改订阅显示名称 |
| `9` | 卸载节点和订阅服务 |

外部订阅支持节点 URI 列表及其 Base64 编码，最多可添加 20 个来源，后台约每 5 分钟刷新一次。

## 恢复、升级和重装

- **安装中断**。如果已经可以运行 `sudo x`，选择 `5` 继续。如果尚未生成管理命令，重新执行安装脚本。
- **更新管理器**。重新执行对应版本的脚本，检测到已有实例时输入 `UPDATE`，再选 `5` 恢复服务。管理器会保留原有实例配置。已有直连域名的实例使用常规版更新。
- **全新重装**。先保存需要保留的信息，再选择 `9` 并输入 `DELETE`。卸载会删除节点、订阅和实例凭据，固定隧道模式还会尝试清理对应的 Cloudflare 资源。卸载完成后重新执行所需版本，获取新凭据和订阅地址。

## 排查

- **临时隧道未分配域名**。运行 `sudo docker logs --tail 80 xiazt-cf`，检查 cloudflared 的连接状态。恢复网络后，运行 `sudo x` 并选 `5`。
- **订阅能打开，节点连不上**。HTTPS 检查只确认订阅入口返回了预期节点链接。请从客户端逐个测试，并核对安全组中的实际 TCP 或 UDP 端口。
- **Hysteria 2 启动失败**。运行 `sudo docker logs --tail 80 xiazt-h2`，检查端口占用和容器启动日志。

[GitHub 仓库](https://github.com/xiazheteng8/xiazheteng-node-manager)
