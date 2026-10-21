# xiazheteng8 Sing-box 节点管理器

一款面向 Ubuntu / Debian VPS 的 Sing-box 节点安装与管理脚本，提供一键安装、节点信息输出、服务管理、内核更新及基础运维功能。

## 项目信息

- **GitHub：** https://github.com/xiazheteng8/xiazheteng-node-manager
- **YouTube：** https://www.youtube.com/@xiazheteng8
- **Telegram：** https://t.me/xiazheteng8

## 一键安装

使用 root 用户登录 VPS，执行以下命令启动脚本：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/xiazheteng8/xiazheteng-node-manager/main/sing-box-manager.sh)
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
| 11–
