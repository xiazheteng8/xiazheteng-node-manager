# 瞎折腾吧｜VPS 多协议节点管理器

一个用于管理 VPS 节点配置、服务状态、订阅信息及配置备份的 Bash 工具。

- **GitHub：** https://github.com/xiazheteng8/xiazheteng-node-manager
- **YouTube：** https://www.youtube.com/@xiazheteng8
- **Telegram：** https://t.me/xiazheteng8

## 一、项目目标

本项目计划将多种代理协议、有证书节点和无证书节点整合到统一的管理入口中，尽量减少 VPS 部署过程中的手动操作。

最终目标是：复制一条启动命令，自动完成环境检测、节点部署、配置验证及订阅生成。

**当前版本说明：** 目前提供的是基础管理框架，尚未实现全部协议的一键部署。请勿将规划中的功能视为已经实现的功能。

## 二、功能状态

| 功能 | 当前状态 |
|---|---|
| VPS 公网 IPv4 检测 | 已实现基础检测 |
| 无域名 / 已解析域名菜单 | 已实现菜单框架 |
| 现有 Xray 配置检查 | 已实现 |
| 现有服务状态检查 | 已实现 |
| 订阅文件查看 | 已实现 |
| 配置备份 | 已实现基础备份 |
| SSH 快捷命令 `X` | 已实现安装逻辑 |
| 自动签发 TLS 证书 | 尚未实现 |
| 自动部署 VLESS-REALITY-Vision | 尚未实现完整部署逻辑 |
| 自动部署 VMess-WS-TLS / Argo | 尚未实现 |
| 自动部署 Hysteria 2 | 尚未实现 |
| 自动部署 TUIC v5 | 尚未实现 |
| 自动部署 AnyTLS | 尚未实现 |
| 多协议统一订阅生成 | 尚未实现完整逻辑 |

## 三、计划支持的节点类型

后续计划整合以下节点类型：

- VLESS-REALITY-Vision
- VMess-WS-TLS
- VMess-WS / Argo
- Hysteria 2
- TUIC v5
- AnyTLS
- Shadowsocks
- 现有有证书及无证书节点

每种协议都需要单独实现服务端配置、启动管理、连接参数生成及客户端订阅格式。只有实际部署成功并通过检查的节点，才能写入最终订阅。

## 四、系统要求

建议使用具有 root 权限的 Linux VPS。

基础管理功能依赖以下工具：

- Bash
- systemd
- curl
- Python 3
- 常见 Linux 系统工具

不同协议的完整部署功能还可能需要额外依赖。当前基础管理脚本不会自动安装全部协议所需的软件。

## 五、下载与运行

### 方法一：从 GitHub 下载

```bash
curl -fL \
  https://raw.githubusercontent.com/xiazheteng8/xiazheteng-node-manager/main/xiazheteng-node-manager.sh \
  -o /root/xiazheteng-node-manager.sh

chmod 700 /root/xiazheteng-node-manager.sh
bash -n /root/xiazheteng-node-manager.sh
bash /root/xiazheteng-node-manager.sh
```

运行前应确认 GitHub 仓库中的脚本内容确实是 Bash 代码，而不是 README 文档。

### 方法二：一条命令启动

确认仓库中的脚本已更新后，可使用：

```bash
bash <(curl -fsSL \
  https://raw.githubusercontent.com/xiazheteng8/xiazheteng-node-manager/main/xiazheteng-node-manager.sh)
```

此命令会执行仓库当前的脚本。请先审阅脚本内容，再在生产 VPS 上运行。

## 六、部署菜单设计

进入“一键部署节点”后，菜单计划采用以下形式：

```text
============== 一键部署节点 ==============

  1. 没有域名
  2. 域名已解析到 203.0.113.10
  0. 返回主菜单

==========================================
```

其中 `203.0.113.10` 仅为格式示例，实际 IP 应由脚本自动检测。

### 1. 没有域名

计划自动部署不依赖自有域名证书的适用节点，并输出实际部署成功的节点信息。

### 2. 域名已解析到 VPS 的 IP 地址

计划自动检测 VPS 公网 IP、检查已有域名及 DNS 解析，并在满足条件时部署需要 TLS 证书的节点。

注意：公网 IP 检测不能自动推断用户的域名。域名需要预先配置，证书也必须成功签发或能够复用。

## 七、现有服务保护

脚本需要兼容以下现有配置：

| 项目 | 路径或服务名 |
|---|---|
| 无证书 Xray 配置 | `/usr/local/etc/xray/node-manager-nocert.json` |
| 无证书 Xray 服务 | `xray-node-manager-nocert.service` |
| 订阅服务 | `node-manager-nocert-subscription.service` |
| 订阅文件 | `/var/lib/node-manager-nocert/subscription.txt` |

安全原则：

1. 不覆盖现有无证书 Xray 配置。
2. 不修改系统默认 `xray.service` 和默认 Xray 配置。
3. 不清空防火墙规则。
4. 不擅自修改 Nginx 网站配置、邮件服务及现有证书。
5. 新增协议应使用独立配置，并在启动前进行配置校验。
6. 删除或恢复操作应明确指定目标，避免误删现有节点。

## 八、SSH 快捷命令

管理器提供安装快捷命
