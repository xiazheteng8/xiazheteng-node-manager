# 瞎折腾吧｜VPS 节点管理器

一个面向 Linux VPS 的节点部署与管理入口，致力于简化无证书 Xray、有证书节点以及 Sing-box 多协议脚本的使用流程，让 VPS 节点部署和日常维护更加方便。

<p align="center">

[YouTube：瞎折腾吧](https://www.youtube.com/@xiazheteng8) · [Telegram 频道](https://t.me/xiazheteng8) · [GitHub 项目](https://github.com/xiazheteng8/xiazheteng-node-manager)

</p>

---

## 🚀 一、VPS 一键启动

登录 Linux VPS，使用 root 权限执行以下命令，即可下载并启动管理菜单：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/xiazheteng8/xiazheteng-node-manager/main/xiazheteng-node-manager.sh)
```

**使用步骤：**

1. SSH 登录你的 VPS。
2. 复制上面的一键启动命令并执行。
3. 等待脚本下载并运行。
4. 根据管理菜单提示选择相应功能。

**适用环境：** 支持 Bash 的 Linux VPS，建议使用 Debian 或 Ubuntu，并确保服务器能够访问 GitHub。

> 安全提醒：该命令会直接执行 GitHub 上的远程脚本。建议先阅读脚本源码，确认操作内容后再执行。已有网站、邮件服务或其他节点的 VPS，请先做好备份。

项目地址：

- GitHub 仓库：https://github.com/xiazheteng8/xiazheteng-node-manager
- 主脚本：https://github.com/xiazheteng8/xiazheteng-node-manager/blob/main/xiazheteng-node-manager.sh

## 📖 二、项目介绍

在 VPS 上部署不同协议的节点时，通常需要使用多个脚本、手动修改配置、检查服务状态并处理端口冲突。

本项目希望提供一个统一入口，集中管理常用操作，减少重复输入命令和切换脚本的麻烦。

项目设计目标：

- **统一管理入口：** 通过一个 Shell 脚本进入管理菜单。
- **无证书节点管理：** 检查指定的独立 Xray 配置和服务状态。
- **有证书及多协议部署：** 提供进入第三方 Sing-box 脚本的入口。
- **配置维护：** 为脚本支持的配置提供备份和恢复操作。
- **订
