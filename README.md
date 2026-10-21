# xiazheteng8 Sing-box 节点管理器

一个用于 Ubuntu / Debian VPS 的 Sing-box 节点部署与管理脚本。

## 项目信息

- **GitHub：** https://github.com/xiazheteng8/xiazheteng-node-manager
- **YouTube：** https://www.youtube.com/@xiazheteng8
- **Telegram：** https://t.me/xiazheteng8

## 功能菜单

### 主菜单

| 选项 | 功能 |
|---|---|
| 1 | 一键安装 Sing-box 内核、生成节点、启动服务并输出连接信息 |
| 2 | 一键卸载本脚本管理的服务和文件 |
| 3–10 | 内核相关设置 |
| 11–14 | 更多功能 |
| x | 创建快捷启动命令 |
| q | 退出 |

### 内核相关设置

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

### 更多功能

| 选项 | 功能 |
|---|---|
| 11 | 尝试启用 BBR + FQ |
| 12 | 查看证书说明 |
| 13 | 检查外部 HTTPS 连通性 |
| 14 | 更新管理脚本 |

## 系统要求

- Ubuntu 或 Debian
- systemd
- root 权限
- 可访问 GitHub 的网络环境
- 可用的公网 IPv4 地址
- 云厂商安全组允许节点端口通信

## 安装方法

将 `sing-box-manager.sh` 上传至 VPS，然后执行：

```bash
chmod +x sing-box-manager.sh
bash sing-box-manager.sh
```

进入菜单后选择 `1`，脚本将尝试安装依赖和 Sing-box 内核，生成 VLESS-Reality 配置，检查配置并启动 systemd 服务。

也可以在脚本已提交到 GitHub 对应分支及路径后，使用：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/xiazheteng8/xiazheteng-node-manager/main/sing-box-manager.sh)
```

## 快捷启动

首次运行菜单时选择 `x`，创建快捷启动命令。

之后可以执行：

```bash
x
```

通过 `x` 启动时，脚本使用持久化副本：

```text
/usr/local/lib/xiazheteng-singbox/sing-box-manager.sh
```

请先将完整脚本提交到仓库，再使用依赖 GitHub 下载的快捷启动和更新功能。

## 节点与订阅说明

脚本当前生成 VLESS-Reality 节点，并将数据保存在以下位置：

| 路径 | 内容 |
|---|---|
| `/etc/xiazheteng-singbox/config.json` | Sing-box 配置 |
| `/etc/xiazheteng-singbox/node.txt` | 节点连接字符串 |
| `/etc/xiazheteng-singbox/subscribe.txt` | Base64 编码的订阅内容 |
| `/usr/local/lib/xiazheteng-singbox/sing-box` | 本项目使用的 Sing-box 内核 |

**重要：当前版本生成的是节点连接字符串和 Base64 订阅内容，并没有实现公网订阅 URL 服务。**

若需要将订阅地址直接填入 v2rayN 等客户端，还需要部署可通过公网访问的订阅服务。通常需要配置域名、HTTPS 和订阅内容更新机制。

## 端口与防火墙

脚本会尝试随机选择未检测到占用的 TCP 端口，并在 UFW 已启用时尝试添加相应规则。

注意：

1. 端口检查和服务绑定之间仍可能发生竞争，不能保证端口永远不会冲突。
2. 云厂商安全组需要单独开放对应 TCP 端口。
3. 脚本不会清空整个防火墙规则。
4. 卸载时请自行检查脚本曾添加的防火墙规则。

## 卸载方法

进入菜单选择 `2`，并输入 `yes` 确认。

脚本会尝试停止并删除本项目创建的服务、配置、快捷入口和独立安装目录。

卸载前请备份需要保留的节点信息。云安全组规则及其他系统防火墙规则需要单独检查。

## 安全与维护说明

- 请在正式使用前检查脚本内容。
- 更新 Sing-box 内核前应确认配置兼容性。
- 不要在生产 VPS 上未经测试直接运行来源不明的脚本。
- 建议保留节点配置备份。
- 当前脚本仅实现基础的 VLESS-Reality 节点部署和运维功能，不应视为完整的多协议管理平台。

## 后续功能规划

以下能力可以作为后续开发目标，但不代表当前版本已经实现：

- 多协议节点部署与统一管理
- 可公网访问的订阅 URL
- 域名证书申请和自动续期
- Argo 隧道管理
- WARP 及代理分流功能
- 更完善的节点分享、订阅更新和配置迁移

## 参考项目与致谢

本项目在功能规划、菜单设计及需求分析阶段参考了勇哥的开源项目：

**yonggekkk/sing-box-yg**

项目地址：https://github.com/yonggekkk/sing-box-yg

感谢勇哥及开源社区分享 Sing-box 部署与管理方面的经验。

本项目使用 `xiazhetng8` 作为脚本顶部品牌标识，围绕本项目的使用需求独立编写管理脚本。若后续直接移植或修改参考项目的代码，应遵循原项目实际适用的许可证及第三方组件的许可证要求。

---

维护者：xiazheteng8

GitHub：https://github.com/xiazheteng8/xiazheteng-node-manager

YouTube：https://www.youtube.com/@xiazheteng8

Telegram：https://t.me/xiazheteng8
