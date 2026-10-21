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
- **订阅信息查看：** 查看现有节点管理模块的订阅信息。
- **简化操作：** 尽量减少重复输入命令，让常用管理操作更直观。

本项目仍在持续完善中。实际功能以仓库当前版本的脚本实现为准。

## ⚙️ 三、功能说明

| 功能 | 说明 |
|---|---|
| 一键启动 | 从 GitHub 下载并启动管理脚本 |
| 统一管理菜单 | 集中进入现有管理功能 |
| Xray 配置检查 | 检查指定配置文件的语法 |
| Xray 服务状态 | 查看指定独立服务的运行状态 |
| Sing-box 上游脚本 | 下载、更新并调用上游脚本 |
| 配置备份与恢复 | 处理管理器支持的配置文件 |
| 订阅信息查看 | 查看现有订阅文件及相关信息 |

### 关于无证书、有证书及多协议

本项目的目标是整合无证书节点、有证书节点和多协议部署入口。

勇哥的 Sing-box 项目是独立的上游脚本，具有自己的部署流程、配置和菜单。通过本项目调用上游脚本，不代表上游的所有协议、证书功能和订阅功能都已合并为本项目独立实现的功能。

上游项目：

https://github.com/yonggekkk/sing-box-yg

具体支持的协议及部署方式，请以本项目当前脚本和上游脚本实际提供的功能为准。

## 📦 四、手动安装

如果不想使用一键启动命令，也可以通过 Git 克隆仓库安装。

### 1. 安装必要工具

Debian / Ubuntu：

```bash
apt-get update
apt-get install -y git curl
```

### 2. 下载项目

```bash
git clone https://github.com/xiazheteng8/xiazheteng-node-manager.git
```

### 3. 进入项目目录

```bash
cd xiazheteng-node-manager
```

### 4. 设置脚本权限

```bash
chmod 700 xiazheteng-node-manager.sh
```

### 5. 启动管理菜单

```bash
bash xiazheteng-node-manager.sh
```

## 🧭 五、管理菜单使用方法

运行脚本后，根据屏幕显示的菜单编号选择功能。

当前管理入口包含以下操作：

| 菜单编号 | 功能 |
|---|---|
| 1 | 启动或调用勇哥 Sing-box 多协议脚本 |
| 2 | 下载或更新上游 Sing-box 脚本 |
| 3 | 检查指定的 Xray 配置 |
| 4 | 查看相关服务状态 |
| 5 | 备份指定配置 |
| 6 | 查看现有备份 |
| 7 | 恢复已有配置备份 |
| 8 | 查看订阅信息 |
| 0 | 退出管理菜单 |

菜单编号以当前脚本实际显示为准。

### 首次使用建议

1. 运行主脚本并查看菜单。
2. 先检查现有 Xray 配置和服务状态。
3. 对已有配置进行备份。
4. 如需使用 Sing-box 多协议功能，进入上游脚本。
5. 根据上游菜单选择所需协议、证书方式和部署模式。
6. 部署完成后，检查服务状态、节点连接信息和端口。

请勿在没有备份的情况下，对已有业务环境执行重装或覆盖操作。

## 🔄 六、日常启动与更新

### 1. 再次启动管理菜单

如果使用一键启动方式，重新执行以下命令：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/xiazheteng8/xiazheteng-node-manager/main/xiazheteng-node-manager.sh)
```

如果使用 Git 克隆方式安装：

```bash
cd /root/xiazheteng-node-manager
bash xiazheteng-node-manager.sh
```

如果项目保存在其他目录，请替换为实际路径。

### 2. 更新主脚本

通过 Git 克隆方式安装的用户执行：

```bash
cd /root/xiazheteng-node-manager
git pull
bash xiazheteng-node-manager.sh
```

如果存在本地修改，请先备份，避免更新时发生冲突。

一键启动方式会重新获取仓库当前的脚本版本，但不会自动保证已经部署的节点配置、上游脚本或服务也同步更新。

### 3. 更新勇哥的上游脚本

可以通过管理菜单提供的更新功能进行操作，也可以查看上游项目的最新说明：

https://github.com/yonggekkk/sing-box-yg

更新前请先备份现有配置，并确认上游脚本的变更不会影响服务器上的其他服务。

## 💾 七、配置备份与恢复

如果当前版本提供相应菜单，可以使用备份、查看备份和恢复功能维护脚本管理的配置文件。

建议另外保存以下重要信息：

- Xray 配置文件。
- UUID、REALITY 参数等节点配置。
- 订阅文件和访问令牌。
- 自定义域名、证书及相关服务配置。
- 自己修改过的脚本。

备份可能包含私钥、密码和订阅令牌等敏感信息。请妥善保管，不要上传到公开仓库。

### 恢复前注意事项

1. 确认备份文件来源和时间。
2. 确认配置文件路径及对应服务。
3. 确认旧配置与当前软件版本兼容。
4. 恢复后检查配置语法和服务状态。
5. 检查网站、邮件及其他节点是否正常运行。

管理器的备份和恢复功能只作用于脚本实际处理的文件，不等同于完整 VPS 系统备份。

## 🌐 八、节点、端口与订阅

节点部署完成后，请以部署脚本实际输出的节点链接和订阅地址为准。

### 端口注意事项

- 检查端口是否已被其他程序占用。
- 确认 VPS 服务商的安全组允许相应流量。
- 检查系统防火墙规则。
- 注意 TCP 和 UDP 端口的区别。
- 避免修改现有 Nginx、网站、邮件服务和节点所使用的端口。

如果当前部署模式支持自动选择随机端口，请以脚本实际执行结果为准。不能仅凭项目设计目标推断所有协议均已实现端口冲突自动处理。

### 订阅注意事项

- 节点链接与订阅链接并不相同。
- 不同协议的客户端兼容性可能不同。
- 订阅服务必须正常运行，访问路径、令牌和端口需要保持一致。
- 订阅无法访问时，应检查服务状态、文件权限、访问路径和防火墙。
- 不要公开分享带有访问令牌的完整订阅地址。

通过上游脚本部署的节点，不一定会自动汇总到本项目现有的订阅文件中。

## 🛠️ 九、常见问题

### 1. 一键启动时提示 curl 不存在

先安装 curl：

```bash
apt-get update
apt-get install -y curl
```

然后重新执行一键启动命令。

### 2. 无法下载 GitHub 脚本

检查网络连接：

```bash
curl -I https://raw.githubusercontent.com/
```

如果无法访问，请检查 DNS、网络出口或下载代理。

### 3. 提示 Permission denied

确认使用 root 权限，并检查脚本权限：

```bash
chmod 700 xiazheteng-node-manager.sh
bash xiazheteng-node-manager.sh
```

### 4. Xray 配置检查失败

如果你的配置文件确实位于以下路径，可以手动测试：

```bash
/usr/local/bin/xray run -test \
  -config /usr/local/etc/xray/node-manager-nocert.json
```

如果安装路径不同，请使用实际的 Xray 程序和配置路径。

常见原因包括 JSON 格式错误、参数缺失、路径不正确或配置与软件版本不兼容。

### 5. 节点部署完成后无法连接

建议检查：

1. 服务是否正常运行。
2. 监听地址和端口是否正确。
3. VPS 安全组和系统防火墙是否放行。
4. 域名、证书及客户端参数是否匹配。
5. 服务日志中是否存在启动失败或握手错误。

### 6. 更新后原有节点异常

先检查配置文件和服务状态，确认是否发生配置覆盖或软件版本变化。必要时恢复备份。

不要在没有确认服务名称和配置路径的情况下，直接重启或覆盖系统已有服务。

## 🔐 十、安全说明

- 执行脚本前，请先检查源码。
- 第三方脚本由其原作者维护，具体行为以对应版本源码为准。
- 不要随意清空现有防火墙规则。
- 不要覆盖已有网站、邮件、证书或代理服务配置。
- 不要将私钥、密码和订阅令牌提交到公开仓库。
- 建议先在测试 VPS 上验证，再应用到重要业务服务器。
- 使用者应确保相关操作符合所在地区法律法规和服务商条款。

## 🔗 十一、项目与频道

- **GitHub 仓库：** https://github.com/xiazheteng8/xiazheteng-node-manager
- **主脚本：** https://github.com/xiazheteng8/xiazheteng-node-manager/blob/main/xiazheteng-node-manager.sh
- **YouTube：瞎折腾吧** https://www.youtube.com/@xiazheteng8
- **Telegram：** https://t.me/xiazheteng8

欢迎关注「瞎折腾吧」，一起分享 VPS、节点部署、网络工具和软硬件折腾过程中的乐趣。

---

<p align="center">

**瞎折腾吧｜只在分享折腾过程中所带来的乐趣**

</p>
