# xiazheteng8 Sing-box 节点管理器

一款面向 Ubuntu / Debian VPS 的 Sing-box 节点安装与管理脚本，提供一键安装、一键卸载、节点部署、内核管理及基础运维功能。

## 项目信息

- **GitHub：** https://github.com/xiazheteng8/xiazheteng-node-manager
- **YouTube：** https://www.youtube.com/@xiazheteng8
- **Telegram：** https://t.me/xiazheteng8

## 一键安装

使用 root 用户登录 VPS，执行以下命令启动脚本：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/xiazheteng8/xiazheteng-node-manager/main/xiazheteng-node-manager.sh)
```

进入菜单后输入 `1`，即可开始一键安装。

一键安装流程：

1. 检查系统环境并安装所需依赖。
2. 安装 Sing-box 内核。
3. 自动生成节点配置。
4. 检查配置文件。
5. 创建并启动 systemd 服务。
6. 输出节点连接信息及订阅内容。

安装完成后，将生成的节点连接导入兼容客户端即可使用。

## 主菜单

```text
1. 一键安装（安装内核、部署节点、输出连接及订阅内容）
2. 一键卸载
3. 内核相关设置
4. 更多功能

输入 x 可快速启动脚本
输入 q 退出
```

### 菜单说明

| 选项 | 功能 |
|---|---|
| 1 | 一键安装内核、部署节点，并输出连接及订阅内容 |
| 2 | 一键卸载本脚本管理的服务及相关配置 |
| 3 | 进入内核相关设置子菜单 |
| 4 | 进入更多功能子菜单 |
| x | 输入 `x` 可快速启动脚本 |
| q | 退出脚本 |

## 内核相关设置

通过主菜单输入 `3` 进入。

| 选项 | 功能 |
|---|---|
| 3 | 查看服务状态 |
| 4 | 重启服务 |
| 5 | 查看运行日志 |
| 6 | 更新 Sing-box 内核 |
| 7 | 查看节点连接信息 |
| 8 | 备份配置 |
| 9 | 检查监听端口 |
| 10 | 返回主菜单 |

## 更多功能

通过主菜单输入 `4` 进入。

| 选项 | 功能 |
|---|---|
| 11 | 尝试启用 BBR + FQ |
| 12 | 查看证书说明 |
| 13 | 检查外部 HTTPS 连通性 |
| 14 | 更新管理脚本 |
| 其他 | 按脚本实际提供的菜单操作 |

## 快捷启动

在脚本菜单中使用快捷启动功能后，后续可以通过以下命令启动管理脚本：

```bash
x
```

输入 `x` 即可快速启动脚本，无需再次输入完整安装命令。

## 节点与订阅

当前基础版本部署的节点类型为 **VLESS + REALITY**。

脚本相关文件路径如下：

| 文件路径 | 用途 |
|---|---|
| `/etc/xiazheteng-singbox/config.json` | Sing-box 配置文件 |
| `/etc/xiazheteng-singbox/node.txt` | 节点连接字符串 |
| `/etc/xiazheteng-singbox/subscribe.txt` | Base64 编码的订阅内容 |
| `/usr/local/lib/xiazheteng-singbox/sing-box` | Sing-box 内核文件 |

### 订阅说明

脚本可以生成节点连接字符串及 Base64 编码的订阅内容。

**本地订阅文件不等于公网订阅链接。** 如果没有部署 HTTP/HTTPS 订阅服务，就不能直接将本地文件路径当作客户端可访问的订阅 URL。

如需公网订阅功能，需要额外部署订阅服务，并配置访问地址、HTTPS 和订阅内容更新机制。

## 系统要求

- Ubuntu 或 Debian
- systemd
- root 权限
- VPS 可以正常访问 GitHub
- 具有可用的公网 IPv4 地址
- 云厂商安全组允许节点端口通信

## 端口与防火墙

脚本会尝试选择未检测到占用的 TCP 端口，并根据脚本实现情况配置相关防火墙规则。

请注意：

1. 端口检查与服务绑定之间仍可能发生竞争，无法保证绝对避免端口冲突。
2. 云厂商安全组需要单独放行节点使用的端口。
3. 不建议为了部署节点而直接清空系统防火墙规则。
4. 卸载后请检查是否仍存在需要清理的防火墙规则。

## 服务管理

### 查看服务状态

进入内核相关设置，选择对应的服务状态选项。

### 重启服务

进入内核相关设置，选择重启服务。

### 查看运行日志

可通过菜单查看运行日志，也可以使用以下命令：

```bash
journalctl -u xiazheteng-singbox -n 100 --no-pager
```

### 配置备份

进入内核相关设置，选择配置备份功能。

建议定期备份节点配置及相关参数，并将备份文件保存到安全的位置。

## 一键卸载

进入主菜单，输入 `2`，按照脚本提示确认卸载。

卸载前请保存需要保留的节点连接、配置文件及备份。

卸载操作的实际清理范围以脚本实现为准。云厂商安全组及其他外部防火墙规则需要单独检查。

## 安全说明

- 建议先在测试 VPS 上验证安装、连接和卸载流程。
- 更新 Sing-box 内核前，应确认新版本与现有配置兼容。
- 节点连接包含访问凭据，请勿随意公开分享。
- Reality 节点能否正常连接，还取决于 VPS 网络、端口连通性及客户端兼容性。
- 使用前请检查脚本内容，并确认其操作符合自身服务器的管理要求。

## 当前版本功能范围

当前基础版本围绕以下功能设计：

- VLESS-Reality 节点部署
- Sing-box 内核安装与更新
- systemd 服务管理
- 节点连接信息输出
- Base64 订阅内容生成
- 配置备份
- BBR + FQ 基础设置
- 快捷启动与卸载

以下功能需以脚本实际实现为准，未实现的功能不能仅凭菜单说明视为可用：

- VMess-WS/TLS、Hysteria2、TUIC、AnyTLS 等多协议部署
- Argo 临时隧道及固定隧道
- ACME 域名证书申请与自动续期
- WARP / Psiphon 代理及分流
- 公网订阅 URL 服务
- 完整的多协议节点管理与订阅转换

## 参考项目与致谢

本项目在功能规划与需求设计阶段参考了勇哥的开源项目：

**yonggekkk/sing-box-yg**

项目地址：https://github.com/yonggekkk/sing-box-yg

感谢勇哥及开源社区分享 Sing-box 部署与管理方面的经验。

本项目围绕自身需求进行开发。如直接移植或修改参考项目的代码，将遵循原项目适用的许可证及相关第三方组件的许可证要求。

---

**项目维护：** xiazheteng8

**GitHub：** https://github.com/xiazheteng8/xiazheteng-node-manager

**YouTube：** https://www.youtube.com/@xiazheteng8

**Telegram：** https://t.me/xiazheteng8
