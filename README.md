# xiazheteng8 Sing-box 节点管理器

一款面向 Ubuntu / Debian VPS 的 Sing-box 节点安装与管理脚本，提供一键安装、节点信息输出、服务管理、内核更新及基础运维功能。

## 项目信息

- **GitHub：** https://github.com/xiazheteng8/xiazheteng-node-manager
- **YouTube：** https://www.youtube.com/@xiazheteng8
- **Telegram：** https://t.me/xiazheteng8

## 一键安装

使用 root 用户登录 VPS，执行以下命令启动脚本：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/xiazheteng8/xiazheteng-node-manager/main/xiazheteng-node-manager.sh)
```

进入菜单后选择 `1`，即可开始一键安装。

安装流程包括：

1. 检查系统环境并安装所需依赖。
2. 下载 Sing-box 内核。
3. 生成 VLESS-Reality 节点配置。
4. 检查配置文件。
5. 创建并启动 systemd 服务。
6. 输出节点连接信息及 Base64 订阅内容。

安装完成后，将终端输出的节点连接导入支持 VLESS-Reality 的客户端即可使用。

## 主菜单

| 选项 | 功能 |
|---|---|
| 1 | 一键安装，生成节点并输出连接信息 |
| 2 | 一键卸载本脚本管理的服务及配置 |
| 3–10 | 内核相关设置 |
| 11–14 | 更多功能 |
| x | 创建快捷启动命令 |
| q | 退出脚本 |

## 内核相关设置

| 选项 | 功能 |
|---|---|
| 3 | 查看服务状态 |
| 4 | 重启服务 |
| 5 | 查看运行日志 |
| 6 | 更新 Sing-box 内核 |
| 7 | 查看节点连接 |
| 8 | 备份配置 |
| 9 | 检查监听端口 |
| 10 | 返回主菜单 |

## 更多功能

| 选项 | 功能 |
|---|---|
| 11 | 尝试启用 BBR + FQ |
| 12 | 查看证书说明 |
| 13 | 检查外部 HTTPS 连通性 |
| 14 | 更新管理脚本 |

## 快捷启动

首次进入菜单后选择 `x`，即可创建快捷启动命令。

以后执行：

```bash
x
```

即可重新打开管理菜单。

## 节点与订阅

当前版本部署的节点类型为 **VLESS + REALITY**。

脚本生成以下文件：

| 文件路径 | 用途 |
|---|---|
| `/etc/xiazheteng-singbox/config.json` | Sing-box 配置文件 |
| `/etc/xiazheteng-singbox/node.txt` | 节点连接字符串 |
| `/etc/xiazheteng-singbox/subscribe.txt` | Base64 编码的订阅内容 |
| `/usr/local/lib/xiazheteng-singbox/sing-box` | 本项目使用的 Sing-box 内核 |

### 订阅说明

当前版本会输出节点连接字符串和 Base64 编码的订阅内容，但**尚未实现公网 HTTP/HTTPS 订阅服务**。

因此，`subscribe.txt` 是 VPS 上的本地文件，不是可直接填入客户端的公网订阅 URL。

如需公网订阅功能，需要进一步部署订阅服务，并配置访问地址、HTTPS 和订阅内容更新机制。

## 系统要求

- Ubuntu 或 Debian
- systemd
- root 权限
- VPS 可正常访问 GitHub
- 具有可用的公网 IPv4 地址
- 云厂商安全组允许节点端口通信

## 端口与防火墙

脚本会尝试随机选择未检测到占用的 TCP 端口，并在 UFW 已启用时尝试添加对应规则。

请注意：

1. 端口检查与服务绑定之间仍可能发生竞争，不能保证完全避免端口冲突。
2. 云厂商安全组需要单独放行节点所使用的 TCP 端口。
3. 脚本不会主动清空系统防火墙规则。
4. 卸载后请检查是否仍有需要清理的防火墙规则。

## 服务管理

### 查看服务状态

进入菜单，选择 `3`。

### 重启服务

进入菜单，选择 `4`。

### 查看日志

进入菜单，选择 `5`。

也可以使用以下命令查看最近的服务日志：

```bash
journalctl -u xiazheteng-singbox -n 100 --no-pager
```

### 配置备份

进入菜单，选择 `8`。

重要配置建议定期备份，并将备份文件保存到安全的位置。

## 一键卸载

进入管理菜单，选择 `2`，按照提示输入 `yes` 确认。

卸载操作会尝试删除本项目管理的服务、配置文件、节点文件、快捷入口和独立内核目录。

**卸载前请先保存需要保留的节点信息和配置备份。**

云厂商安全组规则及其他系统防火墙规则需要单独检查，卸载操作不会自动清理所有外部规则。

## 安全说明

- 请勿在未检查脚本内容的情况下，将其用于重要生产环境。
- 建议首次部署时使用测试 VPS 验证安装、连接和卸载流程。
- 更新 Sing-box 内核前，应确认新版本与现有配置兼容。
- 请勿为了安装节点而直接清空整个防火墙规则。
- 节点连接包含访问凭据，请勿随意公开分享。
- Reality 节点的可用性还取决于 VPS 网络、端口连通性及客户端兼容性。

## 当前版本说明

当前版本主要实现：

- VLESS-Reality 单节点部署
- Sing-box 内核安装与更新
- systemd 服务管理
- 节点连接信息输出
- Base64 订阅内容生成
- 配置备份
- BBR + FQ 基础设置
- 快捷启动与卸载

以下功能尚未完整实现：

- VMess-WS/TLS、Hysteria2、TUIC、AnyTLS 等多协议部署
- Argo 临时隧道及固定隧道
- ACME 域名证书申请与自动续期
- WARP / Psiphon 代理及分流
- 公网订阅 URL 服务
- 完整的多协议节点管理与订阅转换

## 参考项目与致谢

本项目在功能规划、菜单设计及需求分析阶段参考了勇哥的开源项目：

**yonggekkk/sing-box-yg**

项目地址：https://github.com/yonggekkk/sing-box-yg

感谢勇哥及开源社区分享 Sing-box 部署与管理方面的经验。

本项目以 `xiazheteng8` 为品牌标识，围绕自身需求编写管理脚本。若后续直接移植或修改参考项目的代码，将遵循原项目实际适用的许可证及相关第三方组件的许可证要求。

---

**项目维护：** xiazheteng8

**GitHub：** https://github.com/xiazheteng8/xiazheteng-node-manager

**YouTube：** https://www.youtube.com/@xiazheteng8

**Telegram：** https://t.me/xiazheteng8
