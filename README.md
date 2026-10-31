# 🚀 瞎折腾吧 · VPS 一键部署管理器

**一键安装 · 无域名部署 · Cloudflare Tunnel · 在线订阅 · 可视化管理**

<p align="center">
  <a href="https://www.youtube.com/watch?v=6Ot82D5Hn4Q">
    📺 <strong>点击查看完整视频教程（YouTube）</strong>
  </a>
</p>

一款专为 Debian / Ubuntu VPS 打造的自动化部署与管理脚本。通过交互式安装流程，自动完成环境检测、Docker 容器部署、Cloudflare Tunnel 配置、在线订阅生成及日常维护。

无需手动编写复杂配置，**一条命令完成安装，输入 `x` 即可管理。**

**作者：瞎折腾吧**

[GitHub 项目](https://github.com/xiazheteng8/xiazheteng-node-manager) · [脚本源码](https://github.com/xiazheteng8/xiazheteng-node-manager/blob/main/xiazheteng-node-manager-cf-tunnel.sh) · [YouTube](https://www.youtube.com/@xiazheteng8) · [Telegram](https://t.me/xiazheteng8)

---

## 📖 项目介绍

本项目基于 Bash + Python 开发，使用 Docker 部署独立的 3x-ui、Xray、Caddy 和 cloudflared 服务，提供统一的安装、配置、订阅与维护能力。

与需要手动部署多个服务的方式不同，本项目通过一套交互式安装流程完成主要配置，并提供快捷管理菜单，方便后续维护。

**项目特色：**

- 🚀 一键安装，自动准备运行环境
- 🌐 支持无域名部署，自动获取 Cloudflare 临时域名
- ☁️ 支持 Cloudflare 固定隧道及自定义域名
- 🐳 Docker 独立部署，避免接管已有管理面板
- 🔐 管理后台默认不直接暴露公网
- 🔗 自动生成 HTTPS 在线订阅
- 🔄 支持外部订阅聚合与自动刷新
- 🛠️ 支持服务检查、日志查看和故障恢复
- 🗑️ 支持一键卸载脚本创建的资源

## 🧩 技术架构

```text
                  用户 / 客户端
                        │
              HTTPS 订阅与访问
                        │
             ┌──────────┴──────────┐
             │                     │
        自有域名直连          Cloudflare Tunnel
             │                     │
             └──────────┬──────────┘
                        │
                     Caddy
                        │
             ┌──────────┴──────────┐
             │                     │
         WebSocket              订阅服务
             │                     │
           Xray                 Python
             │                     │
             └──────────┬──────────┘
                        │
                  3x-ui 管理
                        │
                  SSH 安全访问
```

脚本还会配置需要公网直连的服务。这些服务不经过普通 Cloudflare HTTP Tunnel，需要按安装结果放行相应端口。

## ✨ 功能说明

| 功能 | 说明 |
|---|---|
| 自动环境检测 | 检查系统、CPU 架构、权限和服务环境 |
| 自动安装依赖 | 安装 Python、Docker、OpenSSL 等组件 |
| 无域名部署 | 自动使用 Cloudflare Quick Tunnel |
| 固定隧道 | 支持 Cloudflare API 自动配置 |
| 独立管理面板 | Docker 运行专用 3x-ui 实例 |
| 在线订阅 | 自动生成 HTTPS 订阅地址 |
| 订阅聚合 | 支持最多 20 个外部订阅 |
| 订阅自定义 | 支持自定义订阅显示名称 |
| 自动缓存 | 外部订阅每 5 分钟刷新 |
| 服务检查 | 检查容器和订阅服务运行状态 |
| 故障恢复 | 支持中断后恢复配置 |
| 一键卸载 | 清理本脚本管理的资源 |

---

# 📋 一、系统要求

安装前请确认 VPS 满足以下条件。

| 项目 | 要求 |
|---|---|
| Debian | 12 / 13 |
| Ubuntu | 22.04 / 24.04 |
| CPU | AMD64 / ARM64 |
| 权限 | root 或 sudo |
| 系统服务 | systemd |
| Docker | 自动安装 |
| 网络 | 可访问互联网 |
| 公网 IP | 需要公网 IPv4 或 IPv6 |
| 域名 | 可选 |

**注意事项：**

- 推荐使用干净的 VPS 系统。
- 脚本需要 SSH 交互式终端。
- 不支持在缺少 systemd 的普通 Docker 容器内直接运行。
- 安装过程中需要下载系统依赖和 Docker 镜像。
- 请提前确认 VPS 的网络连接正常。

# 🚀 二、一键安装

## 2.1 执行安装命令

通过 SSH 连接 VPS，复制以下命令执行：

```bash
curl -fL https://raw.githubusercontent.com/xiazheteng8/xiazheteng-node-manager/main/xiazheteng-node-manager-cf-tunnel.sh -o /tmp/xiazheteng-install.sh && sudo bash /tmp/xiazheteng-install.sh
```

该命令会将脚本下载至 `/tmp/xiazheteng-install.sh`，下载成功后使用 sudo 执行。

首次运行自动进入安装流程，无需额外安装命令。

> 如果系统没有安装 `curl` 或 `sudo`，请先使用系统包管理器安装。建议运行前查看脚本源码。

## 2.2 选择部署方式

脚本提供以下三种模式：

| 选项 | 模式 | 域名要求 | 推荐场景 |
|---|---|---|---|
| `0` | 不使用 CF 隧道 | 需要域名 | 自有域名直连 |
| `1` | 临时 CF 隧道 | 不需要域名 | 新手、快速部署 |
| `2` | 固定 CF 隧道 | 需要 CF 托管域名 | 固定地址部署 |

**没有域名的用户，推荐选择 `1`。**

---

# 🌐 三、无域名部署教程

这是最简单的部署方式。

不需要购买域名，也不需要填写 Cloudflare Account ID 或 API Token。

## 第一步：执行一键安装

```bash
curl -fL https://raw.githubusercontent.com/xiazheteng8/xiazheteng-node-manager/main/xiazheteng-node-manager-cf-tunnel.sh -o /tmp/xiazheteng-install.sh && sudo bash /tmp/xiazheteng-install.sh
```

## 第二步：跳过域名

脚本首先提示：

```text
输入已解析的域名（没有就回车跳过）：
```

**直接按 Enter，不输入任何内容。**

## 第三步：选择临时隧道

终端显示：

```text
CF 隧道：0 不使用 / 1 临时 / 2 固定 [1]：
```

输入：

```text
1
```

也可以直接按 Enter，使用默认的临时隧道模式。

脚本会使用 Cloudflare Quick Tunnel 自动创建临时 HTTPS 地址。

## 第四步：确认 VPS 公网 IP

终端显示类似：

```text
VPS 公网 IP [203.0.113.10]：
```

如果自动检测的 IP 正确，直接按 Enter。

如果检测失败或地址不正确，手动输入 VPS 的公网 IP。

> `203.0.113.10` 仅为示例地址，不能作为真实 VPS 地址使用。

## 第五步：配置后台账号

脚本依次提示：

```text
后台账号 [随机生成]：
后台密码 [回车随机生成]：
```

可以手动输入，也可以直接回车自动生成。

手动设置的后台密码至少需要 12 个字符。

## 第六步：配置其他参数

按照终端提示确认剩余参数，包括目标域名和订阅名称。

例如：

```text
REALITY 目标域名 [www.microsoft.com]：
自定义订阅名称 [我的订阅]：
```

不需要修改时，直接回车使用默认值。

## 第七步：等待自动部署

脚本开始执行：

1. 检测系统环境和可用端口
2. 安装系统依赖及 Docker
3. 下载所需容器镜像
4. 创建独立的管理面板
5. 自动生成服务配置及凭据
6. 启动 Caddy 和订阅服务
7. 启动 Cloudflare 临时隧道
8. 获取 `trycloudflare.com` 地址
9. 验证 HTTPS 订阅是否可以访问

安装时间取决于 VPS 性能及网络速度。

## 第八步：获取订阅地址

安装完成后，终端会显示类似：

```text
订阅：
https://random-name.trycloudflare.com/sub/随机Token
```

复制实际生成的地址，添加至兼容的客户端即可。

后续查看订阅：

```bash
x
```

选择：

```text
1 查看账号/订阅
```

### 无域名部署注意事项

- 临时隧道不需要自有域名。
- 临时隧道地址由 Cloudflare 分配。
- cloudflared 重启后临时域名可能变化。
- 地址变化后，运行 `x` 查看新订阅。
- VPS 仍需具有公网 IP。
- 需要公网直连的服务仍需开放对应端口。

---

# ☁️ 四、有域名部署教程

如果已经拥有域名，可以选择自有域名直连或 Cloudflare 固定隧道。

## 4.1 自有域名直连

首先在 DNS 服务商添加解析记录：

| 记录类型 | 主机记录 | 记录值 |
|---|---|---|
| A | `node` | VPS 公网 IPv4 |
| AAAA | `node` | VPS 公网 IPv6（如适用） |

示例域名：

```text
node.example.com
```

安装时填写：

```text
输入已解析的域名：node.example.com
```

随后选择：

```text
CF 隧道：0 不使用 / 1 临时 / 2 固定 [0]：0
```

脚本会检查域名是否解析到所选公网 IP，并检测 443 端口。

**注意：**

- 域名需正确解析至 VPS。
- 直连模式应关闭 Cloudflare 橙云代理。
- 443 端口必须可用。
- 80 端口可用时可用于 HTTP 证书验证；被占用时脚本会尝试其他支持的验证方式。
- 云服务商安全组和系统防火墙需允许所需流量。

## 4.2 Cloudflare 固定隧道

适合希望使用固定 HTTPS 地址的用户。

### 准备条件

需要：

- Cloudflare 账号
- 已托管在 Cloudflare 的域名
- Cloudflare Account ID
- Cloudflare API Token
- 未被其他 DNS 记录占用的子域名

### API Token 权限

| 权限 | 用途 |
|---|---|
| Tunnel Edit | 创建和管理 Tunnel |
| DNS Edit | 创建和删除对应 DNS 记录 |
| Zone Read | 查询域名 Zone 信息 |

建议将权限范围限制在实际使用的账号和域名。

### 安装操作

运行一键安装命令。

如果只希望通过固定隧道提供 HTTPS 地址，可以在最初的域名提示中直接回车，然后选择 `2`。

```text
输入已解析的域名（没有就回车跳过）：

CF 隧道：0 不使用 / 1 临时 / 2 固定 [1]：2
```

随后按提示填写：

```text
固定隧道域名（CF 托管的空闲子域名）：
Cloudflare Account ID：
Cloudflare API Token：
```

例如：

```text
固定隧道域名：node.example.com
```

脚本会自动尝试：

1. 查询 Cloudflare DNS Zone
2. 检查目标子域名是否存在冲突
3. 创建 Cloudflare Tunnel
4. 配置 Tunnel Ingress
5. 创建 DNS CNAME 记录
6. 启动 cloudflared
7. 验证 HTTPS 订阅

安装成功后，即可通过固定域名访问订阅。

> 固定隧道子域名不要求预先解析到 VPS。请不要提前创建与脚本冲突的 DNS 记录。

---

# 🛠️ 五、快捷管理菜单

安装完成后，输入：

```bash
x
```

进入中文管理菜单。

```text
瞎折腾一键脚本

1 查看账号/订阅
2 添加外部订阅
3 清空外部订阅
4 状态与日志
5 检查/恢复节点
6 重启服务
7 自定义订阅名称
9 一键卸载全部节点
0 退出
```

### 菜单功能

| 选项 | 功能说明 |
|---|---|
| `1` | 查看管理后台、账号密码、订阅地址及端口 |
| `2` | 添加并验证外部订阅 |
| `3` | 清空外部订阅源 |
| `4` | 查看容器状态及日志提示 |
| `5` | 检查并尝试恢复部署 |
| `6` | 重启相关服务并重新检查订阅 |
| `7` | 自定义订阅名称 |
| `9` | 卸载本脚本创建的资源 |
| `0` | 退出管理菜单 |

首次安装后无需重复下载脚本，日常管理直接执行 `x` 即可。

---

# 🔗 六、在线订阅管理

## 6.1 获取订阅地址

执行：

```bash
x
```

选择 `1 查看账号/订阅`。

订阅地址格式：

```text
https://你的域名/sub/随机Token
```

不同部署方式的地址示例：

| 部署方式 | 地址形式 |
|---|---|
| 无域名 | `https://随机名称.trycloudflare.com/sub/Token` |
| 自有域名 | `https://node.example.com/sub/Token` |
| 固定隧道 | `https://cf.example.com/sub/Token` |

请使用脚本实际生成的地址，不要直接使用示例。

## 6.2 添加外部订阅

执行 `x`，选择：

```text
2 添加外部订阅
```

输入需要整合的 HTTPS 订阅 URL。

支持：

- 常见节点 URI 列表
- Base64 编码订阅
- 自动合并与去重
- 最多 20 个外部订阅
- 每 5 分钟刷新一次缓存
- 刷新失败时保留上次成功内容

外部订阅要求为公网 HTTPS 地址，使用标准 443 端口。

**不支持直接解析 Clash YAML 或 JSON 格式的订阅文件。**

## 6.3 清空外部订阅

执行：

```bash
x
```

选择：

```text
3 清空外部订阅
```

此操作会清除已添加的外部订阅源和对应缓存，不会删除本机自动创建的服务配置。

## 6.4 自定义订阅名称

执行：

```bash
x
```

选择：

```text
7 自定义订阅名称
```

输入名称，例如：

```text
我的 VPS 订阅
```

名称支持 1–48 个字符。

修改后，在客户端更新订阅即可。

## 6.5 获取原始订阅

默认订阅返回 Base64 编码内容。

如需查看原始 URI 列表，可在订阅 URL 后添加：

```text
?format=raw
```

示例：

```text
https://node.example.com/sub/随机Token?format=raw
```

---

# 🔐 七、管理后台访问

本项目默认不直接向公网暴露 3x-ui 后台。

后台仅监听 VPS 本机地址，通过 SSH 端口转发访问。

安装完成后，脚本会显示实际的 SSH 转发命令。

例如：

```bash
ssh -N -L 20530:127.0.0.1:20530 root@你的VPS公网IP
```

在自己的电脑终端执行该命令，保持 SSH 连接，然后打开浏览器：

```text
http://127.0.0.1:20530/随机后台路径/
```

输入安装时设置的账号和密码。

**请注意：**

- `20530` 为优先端口，实际端口可能不同。
- 后台路径由脚本随机生成。
- 端口、路径及账号以安装输出为准。
- 无需为了访问后台而向公网开放后台端口。

---

# 🔥 八、端口与防火墙

脚本会检查端口占用情况，并为部分服务自动选择可用端口。

以下是优先使用的端口，并非所有服务器最终都会使用这些端口。

| 服务 | 优先端口 | 公网开放要求 |
|---|---|---|
| 管理后台 | 20530 | 不需要 |
| 在线订阅源站 | 20531 | 不需要 |
| Caddy 内部入口 | 20532 | 不需要 |
| WebSocket 服务 | 20533–20535 | 不需要直接开放 |
| REALITY 直连 | 8443 | TCP |
| Shadowsocks 直连 | 18443 | TCP / UDP |
| 域名 HTTPS 直连 | 443 | TCP |
| HTTP 证书验证 | 80 | 按需开放 TCP |

### 防火墙说明

Cloudflare Tunnel 模式下：

- Cloudflare 隧道使用出站连接。
- 不需要向公网开放隧道内部的 WebSocket 端口。
- 直连服务仍需要相应公网端口。

自有域名直连模式下：

- 需要开放 443/TCP。
- 根据证书验证方式，可能还需要 80/TCP。

脚本**不会自动修改服务器防火墙或云服务商安全组**。

请根据安装完成后输出的实际端口配置规则，不建议直接关闭全部防火墙。

---

# 📊 九、服务状态与日志

## 9.1 查看容器状态

```bash
docker ps -a
```

## 9.2 查看管理面板日志

```bash
docker logs --tail 100 xiazt-panel
```

## 9.3 查看 Caddy 日志

```bash
docker logs --tail 100 xiazt-edge
```

## 9.4 查看 Cloudflare Tunnel 日志

```bash
docker logs --tail 100 xiazt-cf
```

只有启用 Cloudflare Tunnel 时，才会创建 `xiazt-cf` 容器。

## 9.5 查看订阅服务

```bash
systemctl status xiazt-sub
```

## 9.6 查看订阅服务日志

```bash
journalctl -u xiazt-sub -n 100 --no-pager
```

## 9.7 重启全部相关服务

执行：

```bash
x
```

选择：

```text
6 重启服务
```

脚本会重启对应容器和订阅服务，并重新执行公网订阅检查。

---

# 📂 十、项目文件与目录

脚本默认使用以下路径：

```text
/opt/xiazt/
├── manager.py
├── state.json
├── db/
│   └── x-ui.db
├── Caddyfile
├── caddy-data/
├── caddy-config/
├── cache.json
└── cf-token
```

部分文件仅在启用相应功能后生成。

| 路径 | 用途 |
|---|---|
| `/opt/xiazt/` | 项目工作目录 |
| `/opt/xiazt/manager.py` | 管理程序 |
| `/opt/xiazt/state.json` | 安装配置与敏感凭据 |
| `/opt/xiazt/db/` | 3x-ui 数据 |
| `/opt/xiazt/Caddyfile` | Caddy 配置 |
| `/opt/xiazt/cache.json` | 外部订阅缓存 |
| `/opt/xiazt/cf-token` | 固定隧道运行凭据 |
| `/usr/local/bin/x` | 快捷管理命令 |
| `/etc/systemd/system/xiazt-sub.service` | 订阅服务配置 |

**请勿公开 `state.json`、`cf-token` 或包含订阅凭据的文件。**

---

# 🧰 十一、常见问题 FAQ

### Q1：没有域名真的可以部署吗？

可以。

首次安装时域名留空，选择 `1` 临时 Cloudflare Tunnel，即可自动获取临时 HTTPS 地址。

不需要购买域名，也不需要手动配置 Cloudflare API。

### Q2：没有 Cloudflare 账号可以使用吗？

临时隧道模式不需要填写 Cloudflare 账号信息。

固定隧道模式需要 Cloudflare Account ID 和 API Token。

### Q3：临时隧道域名为什么变了？

Cloudflare Quick Tunnel 的地址不是永久固定的。

cloudflared 重新创建临时隧道后，地址可能发生变化。

执行：

```bash
x
```

选择 `1`，重新获取订阅地址。

### Q4：为什么订阅能打开，但客户端连接失败？

订阅地址正常只能证明 HTTPS 订阅服务可访问。

还需要检查：

- 服务器公网 IP 是否正确
- 云服务商安全组是否放行端口
- VPS 防火墙是否放行端口
- 相关 Docker 容器是否正常运行
- 客户端是否支持相应配置
- Cloudflare Tunnel 是否正常连接

建议先通过 `x` 菜单检查服务状态，再通过真实客户端测试连接。

### Q5：443 端口被占用怎么办？

自有域名直连模式需要使用 443 端口。

如果已经有其他程序占用 443，可以考虑改用不需要占用公网 443 端口的 Cloudflare Tunnel 模式。

脚本不会强行停止或接管已有服务。

### Q6：安装中途失败怎么办？

如果已经成功创建了管理程序和状态文件，可尝试：

```bash
x
```

选择：

```text
5 检查/恢复节点
```

脚本会根据已保存的配置继续执行检查和恢复。

如果安装在生成状态文件之前失败，则需要先解决报错，再重新执行安装命令。

### Q7：提示 `/opt/xiazt` 已存在怎么办？

脚本为了避免覆盖已有数据，会拒绝覆盖非空的同名工作目录。

请先确认目录是否属于之前的安装，不要直接删除未知数据。

### Q8：提示 `x` 命令已存在怎么办？

脚本会保护已有的 `/usr/local/bin/x`，避免覆盖其他程序的快捷命令。

请先确认该命令的来源及用途。

### Q9：可以和已有 3x-ui 共存吗？

脚本设计为部署独立的 3x-ui 实例，不主动接管已有面板。

但仍需要避免端口、容器名称、工作目录和快捷命令冲突。

### Q10：能自动配置防火墙吗？

不会。

脚本会输出需要放行的端口，由用户自行配置 VPS 防火墙和云服务商安全组。

---

# 🗑️ 十二、一键卸载

需要删除本项目时，执行：

```bash
x
```

选择：

```text
9 一键卸载全部节点
```

终端会要求输入：

```text
DELETE
```

确认后，脚本会尝试移除：

- 本项目创建的 Docker 容器
- 本项目创建的服务配置
- 项目运行目录
- 管理快捷命令
- 节点和订阅数据
- 由本脚本创建的固定 Cloudflare Tunnel 和 DNS 记录

**卸载属于不可逆操作，执行前请备份重要数据。**

脚本不会主动卸载 Docker，也不会主动删除其他应用。

---

# 🛡️ 十三、安全建议

为确保 VPS 和管理凭据安全，建议：

1. 使用 SSH 密钥登录 VPS。
2. 不要将管理后台直接暴露到公网。
3. 使用高强度后台密码。
4. 不要公开订阅 Token、UUID、密码或私钥。
5. Cloudflare API Token 仅授予必要权限。
6. 不要将项目配置文件上传到公开仓库。
7. 定期更新系统安全补丁。
8. 保留重要配置的离线备份。
9. 不要随意执行来源不明的安装脚本。
10. 避免在承载重要业务的服务器上未经测试直接部署。

---

# ⚙️ 十四、使用的开源组件

本项目使用以下开源软件及服务：

| 项目 | 用途 |
|---|---|
| [3x-ui](https://github.com/MHSanaei/3x-ui) | 管理面板 |
| [Xray-core](https://github.com/XTLS/Xray-core) | 网络服务核心 |
| [Caddy](https://caddyserver.com/) | HTTPS 与反向代理 |
| [cloudflared](https://github.com/cloudflare/cloudflared) | Cloudflare Tunnel |
| [Docker](https://www.docker.com/) | 容器管理 |
| Python 3 | 自动化管理与订阅服务 |

相关组件的版权和许可证归各自项目所有。

---

# ⚠️ 十五、免责声明

本项目仅供合法的技术学习、网络配置及服务器管理用途。

使用者应自行遵守所在地法律法规、网络服务提供商政策和云服务器服务条款。

项目按现状提供，不保证在所有服务器环境中均可正常运行，也不保证第三方服务持续可用。

因部署、使用、修改或卸载本项目造成的服务中断、数据丢失、配置错误或其他损失，使用者应自行评估并承担相关风险。

---

# 📬 十六、项目地址与交流

**项目作者：瞎折腾吧**

| 平台 | 链接 |
|---|---|
| GitHub 仓库 | [xiazheteng-node-manager](https://github.com/xiazheteng8/xiazheteng-node-manager) |
| 当前脚本 | [xiazheteng-node-manager-cf-tunnel.sh](https://github.com/xiazheteng8/xiazheteng-node-manager/blob/main/xiazheteng-node-manager-cf-tunnel.sh) |
| 作者 GitHub | [xiazheteng8](https://github.com/xiazheteng8) |
| YouTube | [瞎折腾吧](https://www.youtube.com/@xiazheteng8) |
| Telegram | [@xiazheteng8](https://t.me/xiazheteng8) |

如果在使用过程中遇到问题，欢迎通过 GitHub Issues 反馈。

---

**⭐ 如果这个项目对你有帮助，欢迎 Star 支持！**

**瞎折腾吧 · 让 VPS 部署更简单。**
