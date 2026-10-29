# 瞎折腾吧｜VPS 一键部署管理脚本

**一键安装 · Cloudflare Tunnel · 在线订阅 · 快捷管理**

一款面向 Debian / Ubuntu VPS 的自动化部署管理工具，集成 Docker、3x-ui、Xray、Caddy 和 Cloudflare Tunnel，支持交互式安装、在线订阅、订阅聚合、服务维护及一键卸载。

[GitHub 项目](https://github.com/xiazheteng8/xiazheteng-node-manager) · [YouTube 频道](https://www.youtube.com/@xiazheteng8) · [Telegram 频道](https://t.me/xiazheteng8)

---

## 功能特点

- **一键安装**：自动检测环境、安装依赖、完成部署。
- **Cloudflare Tunnel**：支持临时隧道和固定隧道。
- **无需域名**：可使用 Cloudflare 临时隧道快速部署。
- **交互式管理**：提供中文菜单和 `x` 快捷命令。
- **独立面板**：使用 Docker 部署 3x-ui 管理面板。
- **在线订阅**：自动生成 HTTPS 订阅地址。
- **订阅聚合**：支持外部订阅添加、去重及定时刷新。
- **安全管理**：管理后台默认仅监听本机地址。
- **服务维护**：支持日志查看、服务重启及故障恢复。
- **一键卸载**：清理本项目创建的相关服务和配置。

## 系统要求

| 项目 | 要求 |
|---|---|
| 操作系统 | Debian 12 / 13、Ubuntu 22.04 / 24.04 |
| CPU 架构 | AMD64 / ARM64 |
| 执行权限 | root / sudo |
| 服务管理 | systemd |
| 网络环境 | 可访问互联网 |
| 域名 | 可选 |

## 一键安装

SSH 登录 VPS 后，复制执行以下命令：

```bash
curl -fL https://raw.githubusercontent.com/xiazheteng8/xiazheteng-node-manager/main/xiazheteng-node-manager-cf-tunnel.sh -o /tmp/xiazheteng-install.sh && sudo bash /tmp/xiazheteng-install.sh
```

脚本会自动检测系统环境并启动交互式安装。

> 建议安装前查看脚本源码，并确认服务器上没有与本项目冲突的服务。

## 部署方式

| 模式 | 域名要求 | 适用场景 |
|---|---|---|
| 直连模式 | 已解析域名 | 使用自有域名部署 |
| 临时 CF Tunnel | 无需域名 | 快速部署与测试 |
| 固定 CF Tunnel | Cloudflare 托管域名 | 长期使用固定地址 |

临时隧道会自动分配 HTTPS 地址，但服务重启后地址可能发生变化。

固定隧道需要 Cloudflare Account ID、API Token 和可使用的子域名。

## 安装流程

执行一键安装命令后，根据提示：

1. 输入域名，没有域名可直接回车。
2. 选择部署模式。
3. 配置 VPS 公网地址。
4. 设置后台账号及密码。
5. 填写所选模式需要的配置。
6. 等待脚本自动安装、启动和验证服务。
7. 保存安装结果中的后台信息和订阅地址。

## 快捷管理

安装完成后，输入：

```bash
x
```

即可打开管理菜单：

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

## 在线订阅

安装成功后，系统会生成专属 HTTPS 订阅地址，例如：

```text
https://你的域名/sub/随机Token
```

支持自动生成本机订阅、添加外部订阅、去重合并、自定义订阅名称及缓存刷新。

最多支持 20 个外部订阅源，默认每 5 分钟刷新缓存。

## 管理面板

管理面板默认仅允许 VPS 本机访问，需要通过 SSH 端口转发在本地浏览器打开。

后台端口、账号、密码及随机访问路径以安装完成后的输出为准。

## 服务维护

查看容器状态：

```bash
docker ps -a
```

查看管理面板日志：

```bash
docker logs --tail 100 xiazt-panel
```

查看 Cloudflare Tunnel 日志：

```bash
docker logs --tail 100 xiazt-cf
```

查看订阅服务：

```bash
systemctl status xiazt-sub
```

如需重启、检查或恢复服务，直接执行 `x` 并选择相应菜单。

## 常见问题

**没有域名可以使用吗？**

可以。安装时选择临时 Cloudflare Tunnel 模式即可。

**为什么临时订阅地址变化了？**

临时 Cloudflare Tunnel 分配的地址不保证长期固定，服务重启后可能变化。

**后台无法访问怎么办？**

确认已建立 SSH 端口转发，并使用安装时显示的后台端口和访问路径。

**订阅无法访问怎么办？**

检查 Docker 容器、订阅服务、Cloudflare Tunnel 和 DNS 配置。

**如何卸载？**

输入 `x`，选择 `9 一键卸载全部节点`，按照提示确认。卸载前请备份重要数据。

## 安全提示

- 请勿泄露管理账号、密码、订阅 Token 或 Cloudflare API Token。
- 不建议将管理后台直接暴露至公网。
- 不要随意关闭 VPS 防火墙。
- 安装前确认端口和已有服务是否冲突。
- 重要服务器请提前备份配置。

## 免责声明

本项目仅供合法的技术学习、服务器管理和网络配置用途。

使用者应遵守所在地法律法规及服务商相关规定，自行评估部署和使用风险。

本项目按现状提供，不保证适用于所有服务器环境。

## 相关链接

- **项目仓库：** https://github.com/xiazheteng8/xiazheteng-node-manager
- **脚本源码：** https://github.com/xiazheteng8/xiazheteng-node-manager/blob/main/xiazheteng-node-manager-cf-tunnel.sh
- **YouTube：** https://www.youtube.com/@xiazheteng8
- **Telegram：** https://t.me/xiazheteng8

---

**瞎折腾吧 · 让 VPS 部署与管理更简单。**
