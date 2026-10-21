# 瞎折腾吧｜VPS 节点管理器

一个面向 Linux VPS 的 Shell 管理入口，集中提供 Xray 配置检查、服务状态查看、配置备份与恢复、订阅信息查看，以及勇哥 Sing-box 多协议脚本的调用入口。

<p align="center">

[YouTube：瞎折腾吧](https://www.youtube.com/@xiazheteng8) · [Telegram](https://t.me/xiazheteng8) · [GitHub](https://github.com/xiazheteng8/xiazheteng-node-manager)

</p>

---

## 🚀 一、VPS 一键启动

使用 root 账号登录 VPS，执行以下命令：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/xiazheteng8/xiazheteng-node-manager/main/xiazheteng-node-manager.sh)
```

脚本下载成功后会进入管理菜单。

**基本步骤：**

1. SSH 登录 Linux VPS。
2. 复制上面的一键启动命令。
3. 等待脚本下载并启动。
4. 根据菜单选择需要的功能。

建议使用 Debian 或 Ubuntu，并确保 VPS 可以访问 GitHub。

> 安全提示：该命令会直接执行 GitHub 上的远程脚本。执行前建议检查源码。已有网站、邮件服务或节点的 VPS，请先备份配置。

### 项目地址

- GitHub 仓库：https://github.com/xiazheteng8/xiazheteng-node-manager
- 主脚本：https://github.com/xiazheteng8/xiazheteng-node-manager/blob/main/xiazheteng-node-manager.sh
- 勇哥 Sing-box 上游项目：https://github.com/yonggekkk/sing-box-yg

## 📖 二、项目介绍

在 VPS 上部署节点时，常常需要分别运行不同脚本、检查配置、查看服务状态并维护备份。

本项目提供一个统一管理入口，方便执行常用的维护操作，并调用第三方 Sing-box 多协议脚本。

### 当前脚本提供的功能

| 菜单 | 功能 |
|---|---|
| 1 | 下载或执行勇哥 Sing-box 多协议脚本 |
| 2 | 下载或更新勇哥 Sing-box 脚本 |
| 3 | 检查指定的 Xray 配置 |
| 4 | 查看指定 Xray 与订阅服务的状态 |
| 5 | 备份脚本指定的配置文件 |
| 6 | 查看已有备份 |
| 7 | 恢复已有备份 |
| 8 | 查看订阅文件信息 |
| 0 | 退出 |

### 关于有证书、无证书和多协议

本项目的管理入口与勇哥的 Sing-box 脚本是两个不同的部分。

- Xray 检查功能针对脚本中指定的独立配置文件。
- Sing-box 多协议部署由上游脚本负责。
- 上游脚本的协议、证书和部署方式，以其实际版本为准。
- 本项目当前版本不会自动将上游所有节点合并为统一订阅，也不应被视为完整融合了上游的全部功能。

## 📦 三、手动安装

如果不使用一键启动命令，可以通过 Git 克隆仓库。

### 1. 安装必要工具

Debian / Ubuntu：

```bash
apt-get update
apt-get install -y git curl
```

### 2. 下载项目并启动

```bash
git clone https://github.com/xiazheteng8/xiazheteng-node-manager.git
cd xiazheteng-node-manager
chmod 700 xiazheteng-node-manager.sh
bash xiazheteng-node-manager.sh
```

## 🧭 四、日常使用

### 再次打开管理菜单

如果通过 Git 克隆安装：

```bash
cd /root/xiazheteng-node-manager
bash xiazheteng-node-manager.sh
```

如果使用一键启动方式，则重新执行第一节中的命令。

### 更新主脚本

通过 Git 克隆安装：

```bash
cd /root/xiazheteng-node-manager
git pull
bash xiazheteng-node-manager.sh
```

如果本地修改过脚本，请先备份，再更新。

一键启动命令会重新下载当前仓库的主脚本，但不会自动更新已经部署的节点配置或所有上游服务。

### 使用勇哥 Sing-box 脚本

在主菜单中选择 `1`，按提示下载或更新上游脚本，并确认后运行。

也可以选择 `2`，只下载或更新上游脚本，不立即运行。

上游脚本可能会安装软件、修改服务、端口或防火墙规则。执行前请阅读其提示，并确认不会影响 VPS 上已有的网站、邮件或节点服务。

上游项目：https://github.com/yonggekkk/sing-box-yg

## 🔍 五、Xray 配置检查

当前脚本检查的配置路径为：

```text
/usr/local/etc/xray/node-manager-nocert.json
```

Xray 程序路径为：

```text
/usr/local/bin/xray
```

如果实际环境与上述路径不同，需要先调整主脚本中的对应变量。

也可以手动测试配置：

```bash
/usr/local/bin/xray run -test \
  -config /usr/local/etc/xray/node-manager-nocert.json
```

如果提示 `Configuration OK.`，表示该配置通过了 Xray 的语法检查；这不代表节点一定能够从公网连接。

**注意：** 本项目不会因为系统默认 `xray.service` 异常，就自动覆盖或重启它。请确认服务名称和配置路径后再操作。

## 💾 六、配置备份与恢复

备份目录：

```text
/root/xiazheteng-node-manager-backups/
```

当前脚本尝试备份以下文件：

```text
/usr/local/etc/xray/node-manager-nocert.json
/var/lib/node-manager-nocert/subscription.txt
/usr/local/bin/node-manager-nocert-subscription.py
```

不存在的文件会被跳过。

通过菜单可以：

- 备份当前存在的指定文件。
- 查看已创建的备份目录。
- 选择一个备份目录恢复对应文件。

### 恢复注意事项

恢复操作会覆盖对应的现有文件。执行前请确认备份来源和时间。

恢复后，建议重新检查配置语法与服务状态。本脚本不会自动重启服务，也不提供完整 VPS 系统级备份。

备份中可能包含私钥、UUID 或订阅令牌，请妥善保管，不要上传到公开仓库。

## 🌐 七、订阅信息

菜单中的订阅功能默认检查：

```text
/var/lib/node-manager-nocert/subscription.txt
```

并查看以下服务的状态：

```text
node-manager-nocert-subscription.service
```

当前脚本只显示订阅文件的路径、大小、权限和服务状态，不直接打印完整订阅内容，以降低敏感链接意外泄露的风险。

如果你的服务器使用不同的订阅文件或服务名称，需要调整主脚本中的配置变量。

## 🛠️ 八、常见问题

### 1. 一键启动时提示 curl 不存在

先安装 curl：

```bash
apt-get update
apt-get install -y curl
```

然后重新执行一键启动命令。

### 2. 提示无法访问 GitHub

检查网络：

```bash
curl -I https://raw.githubusercontent.com/
```

如果无法连接，请检查 DNS、网络出口或代理配置。

### 3. 脚本提示语法错误

运行：

```bash
bash -n xiazheteng-node-manager.sh
```

如果出现 `<p align="center">`、`# 项目介绍` 等内容被当作 Shell 语法的错误，说明 Markdown 被错误地写入了 `.sh` 文件。

正确的文件分工是：

- `xiazheteng-node-manager.sh`：只包含 Bash 代码。
- `README.md`：包含项目介绍和使用文档。

### 4. Xray 配置检查失败

检查配置路径、JSON 格式、必要参数以及 Xray 版本兼容性。

不要在没有确认路径的情况下，直接覆盖现有 Xray 配置。

### 5. 节点部署后无法连接

建议依次检查：

1. 对应服务是否运行。
2. 监听端口是否正确。
3. VPS 安全组和系统防火墙是否放行。
4. 域名、证书和客户端参数是否一致。
5. 服务日志是否存在启动或握手错误。

不同协议的排查方式不同，请参考实际部署脚本的说明。

## 🔐 九、安全说明

- 执行远程脚本前请检查源码。
- 不要随意清空现有防火墙规则。
- 不要覆盖已有网站、邮件、证书和代理服务配置。
- 不要公开上传私钥、密码或订阅令牌。
- 第三方脚本的实际行为以对应版本源码为准。
- 建议先在测试 VPS 上验证，再应用到重要业务服务器。

## 🔗 十、项目与频道

- **GitHub 仓库：** https://github.com/xiazheteng8/xiazheteng-node-manager
- **主脚本：** https://github.com/xiazheteng8/xiazheteng-node-manager/blob/main/xiazheteng-node-manager.sh
- **YouTube：瞎折腾吧** https://www.youtube.com/@xiazheteng8
- **Telegram：** https://t.me/xiazheteng8

欢迎关注「瞎折腾吧」，一起分享 VPS、节点部署、网络工具和软硬件折腾过程中的乐趣。

---

## 免责声明

本项目仅供技术学习、测试和合法用途。请遵守所在地区法律法规及服务提供商的相关条款。使用者应自行评估风险，并对自己的服务器、配置和数据负责。

<p align="center">

**瞎折腾吧｜分享折腾过程中所带来的乐趣**

</p>
