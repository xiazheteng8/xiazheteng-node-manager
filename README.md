# 瞎折腾吧｜VPS 多协议节点管理器

一款面向 Debian / Ubuntu VPS 的自动化节点部署与管理脚本，支持常用节点部署、快捷菜单、节点分享链接生成、订阅聚合及相关维护操作。

<p align="center">

**作者：瞎折腾吧**

[GitHub 仓库](https://github.com/xiazheteng8/xiazheteng-node-manager) · [主脚本](https://github.com/xiazheteng8/xiazheteng-node-manager/blob/main/xiazheteng-node-manager.sh) · [YouTube 频道](https://www.youtube.com/@xiazheteng8) · [Telegram 频道](https://t.me/xiazheteng8)

</p>

---

# 瞎折腾吧｜VPS 节点一键部署管理系统

一个面向 Debian / Ubuntu VPS 的交互式 Bash 管理脚本，用于部署和管理 Xray 节点、生成节点订阅，并提供在线订阅服务。

> 本项目适用于具备 Linux 与服务器基础知识的用户。运行前请阅读本文，确认脚本操作符合你的使用场景。

## 功能

- 自动检测系统环境、安装依赖并下载适配系统架构的 Xray。
- 一键生成并部署 VLESS REALITY 与 Shadowsocks 节点。
- 在域名解析和证书申请条件满足时，额外部署 VLESS WebSocket + TLS 节点。
- 自动检查端口占用，并选择可用端口。
- 生成节点分享链接及 Base64 订阅内容。
- 创建独立的 systemd 服务，分别管理 Xray 和在线订阅服务。
- 提供交互式菜单，用于安装/修复、刷新订阅、显示订阅链接和卸载本脚本管理的组件。
- 可创建 `x` 快捷命令，方便再次打开管理菜单。

节点类型和可用功能取决于当前服务器环境。例如，没有可用域名或证书时，TLS 节点会跳过；REALITY 密钥生成失败时，REALITY 节点也可能跳过。

## 系统要求

| 项目 | 要求 |
| --- | --- |
| 系统 | Debian 或 Ubuntu |
| 权限 | root |
| 网络 | VPS 可访问互联网并下载系统依赖及 Xray |
| 网络地址 | 建议具备公网 IPv4 |
| 域名 | 可选；部署 TLS 节点需要域名解析到本机并满足证书申请条件 |
| 放行端口 | 节点端口及在线订阅端口需在 VPS 防火墙和云服务商安全组中放行 |

脚本会安装所需系统依赖，并从 Xray 官方 GitHub Releases 下载 Xray。首次安装请确保服务器可以访问相关软件源和下载站点。

## 安装与启动

以 root 身份通过 SSH 登录 VPS，执行：

```bash
普通版
apt update
apt install -y curl ca-certificates
curl -4 -fsSL \
  https://raw.githubusercontent.com/xiazheteng8/xiazheteng-node-manager/main/xiazheteng-node-manager.sh \
  -o /root/xiazheteng-node-manager.sh
chmod 700 /root/xiazheteng-node-manager.sh
bash /root/xiazheteng-node-manager.sh
```
```bash
CF隧道版
apt update
apt install -y curl ca-certificates
curl -4 -fsSL \
  https://raw.githubusercontent.com/xiazheteng8/xiazheteng-node-manager/main/xiazheteng-node-manager-cf-tunnel.sh \
  -o /root/xiazheteng-node-manager-cf-tunnel.sh
chmod 700 /root/xiazheteng-node-manager-cf-tunnel.sh
bash /root/xiazheteng-node-manager-cf-tunnel.sh
```

也可以在本地下载脚本后上传到 VPS，再以 root 身份运行：

```bash
bash /root/xiazheteng-node-manager.sh
```

首次启动时，脚本会询问域名。没有域名时直接回车即可使用不含 TLS 节点的部署方式；需要 TLS 节点时，请输入已解析到本 VPS 的域名。

## 菜单说明

| 选项 | 功能 |
| --- | --- |
| `1` | 一键安装 / 自动修复：检查环境、准备 Xray 和订阅端口、生成节点配置并启动服务 |
| `2` | 卸载脚本管理的组件 |
| `3` | 整合订阅 / 刷新订阅：重新生成节点订阅，并刷新在线订阅服务 |
| `4` | 创建快捷命令 `x` |
| `5` | 显示在线订阅链接 |
| `0` | 退出管理器 |

### 创建快捷命令

在菜单中选择 `4` 后，后续可在 SSH 终端输入：

```bash
x
```

重新打开管理菜单。

## 部署后检查

安装完成后，保存终端显示的在线订阅链接，并在兼容的客户端中添加订阅、更新节点列表。请确认：

1. VPS 防火墙已放行脚本显示的节点端口和订阅端口。
2. 云服务商控制台中的安全组也已放行这些端口。
3. 域名模式下，DNS 记录指向正确的 VPS，证书有效。
4. 客户端支持相应的协议和传输参数。

本机服务启动成功不代表端口一定能从公网访问，也不代表节点一定能通过客户端连接测试。

## 文件与服务

脚本主要使用以下路径：

| 路径 | 用途 |
| --- | --- |
| `/opt/xiazheteng-node/` | 项目运行文件、Xray、配置和数据 |
| `/opt/xiazheteng-node/data/nodes.json` | 节点配置清单 |
| `/opt/xiazheteng-node/data/subscription.txt` | 明文节点分享链接列表 |
| `/opt/xiazheteng-node/data/subscription.b64` | Base64 编码订阅内容 |
| `/opt/xiazheteng-node/data/subscription-url.txt` | 在线订阅地址 |
| `/var/log/xiazheteng-node-manager/manager.log` | 管理器日志 |
| `xiazheteng-xray` | Xray systemd 服务 |
| `xiazheteng-subscription` | 在线订阅 systemd 服务 |

配置文件和订阅链接包含敏感信息，请勿公开发布或上传到不可信位置。

## 卸载说明

菜单选项 `2` 会尝试停止并移除本脚本创建的 systemd 服务、快捷命令和项目目录。卸载前请备份需要保留的配置或节点信息。

脚本不会自动卸载系统依赖、acme.sh，也不会清除防火墙规则。请根据自身服务器情况手动检查这些项目。

## 常见问题

### 提示需要 root 权限

请使用 root 登录，或通过 `sudo -i` 切换到 root 后重新运行。

### 订阅刷新时报端口未配置或 `SUB_PORT` 未定义

请确认曾成功完成“一键安装 / 自动修复”，且 `/opt/xiazheteng-node/data/subscription-port.env` 存在并包含有效端口。若使用旧版本脚本，可先重新下载最新脚本，再运行菜单选项 `3`；仍有问题时选择选项 `1` 执行修复。

### TLS 节点没有生成

请检查域名 A 记录是否指向 VPS、公网 IPv4 是否可检测，以及证书申请条件是否满足。脚本不会为了申请证书自动停止已经占用端口的服务。

### 订阅可访问但节点无法连接

请检查对应服务状态、节点端口监听、VPS 防火墙、云安全组以及客户端协议参数。订阅 HTTP 请求成功只说明订阅服务可访问，不代表节点连接可用。

### 查看服务状态和日志

```bash
systemctl status xiazheteng-xray
systemctl status xiazheteng-subscription
journalctl -u xiazheteng-xray -n 100 --no-pager
journalctl -u xiazheteng-subscription -n 100 --no-pager
```

## 安全与使用提醒

- 部署前确认你有权管理该 VPS，并遵守所在地法律法规及云服务商使用条款。
- 不要公开分享订阅链接、UUID、密码、私钥或包含这些信息的配置文件。
- 执行卸载或修改配置前，先备份需要保留的数据。
- 不要为了让节点工作而直接关闭整个防火墙；只开放所需端口。
- 如果 VPS 同时承载网站或其他业务，请先检查端口占用和服务影响。

## 免责声明

本项目按现状提供，仅供合法的技术学习、服务器管理和网络配置用途。使用者须自行评估风险并遵守适用法律法规及服务条款。因使用、修改或无法使用本项目而导致的配置错误、服务中断、数据损失或其他损失，由使用者自行承担；项目作者不对相关损失承担责任。

## 项目地址

- GitHub 仓库：[xiazheteng8/xiazheteng-node-manager](https://github.com/xiazheteng8/xiazheteng-node-manager)
- 主脚本：[xiazheteng-node-manager.sh](https://github.com/xiazheteng8/xiazheteng-node-manager/blob/main/xiazheteng-node-manager.sh)
- YouTube：[瞎折腾吧](https://www.youtube.com/@xiazheteng8)
- Telegram：[t.me/xiazheteng8](https://t.me/xiazheteng8)


**项目名称：** 瞎折腾吧｜VPS 多协议节点管理器

**主脚本：** `xiazheteng-node-manager.sh`

**维护仓库：** [xiazheteng8/xiazheteng-node-manager](https://github.com/xiazheteng8/xiazheteng-node-manager)
