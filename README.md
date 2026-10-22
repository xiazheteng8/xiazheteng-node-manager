# 瞎折腾吧｜VPS 多协议节点管理器

一款面向 Debian / Ubuntu VPS 的自动化节点部署与管理脚本，支持常用节点部署、快捷菜单、节点分享链接生成、订阅聚合及相关维护操作。

<p align="center">

**作者：瞎折腾吧**

[GitHub 仓库](https://github.com/xiazheteng8/xiazheteng-node-manager) · [主脚本](https://github.com/xiazheteng8/xiazheteng-node-manager/blob/main/xiazheteng-node-manager.sh) · [YouTube 频道](https://www.youtube.com/@xiazheteng8) · [Telegram 频道](https://t.me/xiazheteng8)

</p>

---

## 一、项目介绍

「瞎折腾吧｜VPS 多协议节点管理器」旨在简化 VPS 节点的部署、配置和维护流程，将常用操作整合到一个交互式 Bash 菜单中。

无需每次都手动输入大量命令，即可根据菜单提示完成相应操作。

### 主要特点

- **一键启动**：下载脚本后即可运行。
- **快捷菜单**：安装完成后，可通过 SSH 输入 `x` 快速启动管理器。
- **节点部署**：提供脚本支持的节点部署方式及相关配置。
- **自动参数生成**：根据所选部署模式生成相应配置和节点分享链接。
- **订阅聚合**：尝试收集脚本能够识别的节点分享链接。
- **域名与 HTTPS**：支持相应的证书申请及订阅站点配置流程。
- **端口检测**：检测端口占用，并在适用场景下选择可用端口。
- **冲突检查**：对部分现有 Nginx 站点和配置进行检测，尽量避免覆盖其他服务。
- **菜单式管理**：将部署、配置和维护操作集中处理。

> 注意：实际支持的协议、传输方式和部署选项，以仓库当前版本的脚本为准。订阅聚合也无法保证识别所有第三方脚本生成的配置。

## 二、系统要求

建议使用具备公网 IPv4 地址的 Linux VPS。

| 项目 | 要求 |
|---|---|
| 操作系统 | Debian / Ubuntu |
| 权限 | root 或具备完整管理权限的账号 |
| 网络 | VPS 能够访问互联网并下载依赖 |
| 架构 | 以脚本和相关软件的实际兼容性为准 |
| 域名 | 可选；使用 HTTPS 订阅时需要配置域名 |
| 防火墙 | 根据节点协议放行相应端口 |

**重要提示：** VPS 本机防火墙放行端口，并不代表云服务商的安全组也已放行。部署完成后，需要确认端口能够从外部正常访问。

## 三、一键安装与启动

登录 VPS，通过 SSH 执行以下命令：

```bash
apt update
apt install -y curl ca-certificates

curl -4 -fsSL \
  https://raw.githubusercontent.com/xiazheteng8/xiazheteng-node-manager/main/xiazheteng-node-manager.sh \
  -o /root/xiazheteng-node-manager.sh

chmod 700 /root/xiazheteng-node-manager.sh

bash /root/xiazheteng-node-manager.sh
```

脚本地址：

[https://github.com/xiazheteng8/xiazheteng-node-manager/blob/main/xiazheteng-node-manager.sh](https://github.com/xiazheteng8/xiazheteng-node-manager/blob/main/xiazheteng-node-manager.sh)

运行后，根据终端提示选择需要的功能。

### 快捷启动

如果脚本已经成功安装快捷入口，后续登录 SSH 后可以直接输入：

```bash
x
```

即可启动管理菜单。

如果提示 `x: command not found`，请重新运行脚本，检查快捷入口是否创建成功，以及 `/usr/local/bin` 是否位于当前用户的 `PATH` 中。

## 四、节点部署说明

节点部署流程取决于脚本当前提供的菜单选项。

一般操作流程如下：

1. 运行管理器。
2. 选择需要部署的节点类型。
3. 按照提示输入域名、端口或其他必要参数。
4. 等待脚本完成相应配置。
5. 保存生成的节点分享链接。
6. 使用客户端导入节点，并进行连接测试。

节点能否正常使用，取决于服务端配置、网络连通性、客户端兼容性及相关参数是否一致。

### 节点参数检查

如果节点无法连接，请重点核对：

- 服务器地址与端口是否正确。
- 节点服务是否正常运行。
- UUID、密钥及其他认证参数是否匹配。
- TLS、REALITY、SNI、Short ID 等参数是否一致。
- VPS 防火墙与云服务商安全组是否放行相应端口。

## 五、订阅聚合

脚本提供订阅聚合相关功能，尝试扫描能够识别的节点配置，并汇总对应的分享链接。

如果使用域名与 HTTPS 订阅模式，需要先完成域名解析、证书申请及相关 Web 服务配置。

### 域名与 HTTPS 订阅

使用前请确认：

1. 域名已经解析到正确的 VPS。
2. 证书申请所需的网络条件满足要求。
3. 80 端口及相关 Web 服务没有不可解决的冲突。
4. Nginx 配置检查通过。
5. 订阅目录和访问路径配置正确。

如果 VPS 已经运行网站，请在修改配置前备份现有文件。

### 无域名模式

如果暂时没有域名，可以按照脚本提供的无域名部署选项操作。

无域名模式的实际功能取决于当前部署方式，不能默认认为所有客户端都支持通过裸 IP 使用 HTTPS 订阅。

### 订阅兼容性

订阅聚合需要完整的节点参数才能生成有效分享链接。

如果某个节点配置缺少服务器地址、UUID、端口或必要的传输参数，可能无法自动生成有效链接。

建议在生成订阅后，使用实际客户端导入并测试，不要只根据订阅文件能够打开就判断节点可用。

## 六、常见问题

### 1. 输入 `x` 无法启动

检查快捷入口是否存在：

```bash
ls -l /usr/local/bin/x
ls -l /usr/local/bin/xiazheteng-node-manager.sh
```

如果文件不存在，请重新运行主脚本，并确认脚本具有正确的执行权限。

### 2. 节点测速显示 `-1`

这通常表示客户端没有获得有效的延迟测试结果，可能原因包括：

- 服务器端口不可访问。
- 节点服务未启动。
- DNS 解析错误。
- TLS 或 REALITY 参数不匹配。
- 客户端不支持当前节点配置。
- VPS 网络或云安全组限制。

建议依次检查服务状态、端口监听、防火墙及客户端参数。

### 3. 域名证书申请失败

检查域名是否解析正确、80 端口是否可以从外部访问，以及 Nginx 是否正常运行。

如果域名使用了 CDN 或代理服务，还需要确认该代理模式是否影响当前证书申请方式。

### 4. Nginx 提示端口占用

先检查当前监听端口：

```bash
ss -lntp
```

再检查 Nginx 配置：

```bash
nginx -t
```

不要在未确认业务影响的情况下直接停止 Nginx、删除配置文件或覆盖现有网站。

### 5. 订阅可以打开，但客户端没有节点

请检查：

- 返回内容是否为有效订阅格式。
- 节点分享链接是否包含必要参数。
- 订阅聚合是否识别了对应节点配置。
- 客户端是否支持该节点类型。

HTTP 请求成功并不等于订阅内容和节点连接一定有效。

## 七、安全建议

- 不要在生产 VPS 上未经检查就运行未知脚本。
- 修改 Nginx、证书或节点配置前，应先备份。
- 不要公开上传包含私钥、UUID、订阅令牌或其他敏感信息的文件。
- 不要将个人订阅地址随意分享给他人。
- 不要为了部署节点而随意关闭整个防火墙。
- 如果 VPS 同时运行网站、邮件服务或其他业务，请先检查端口和配置冲突。
- 建议定期更新系统及相关软件，并检查服务日志。

## 八、项目地址

- **GitHub 仓库：** https://github.com/xiazheteng8/xiazheteng-node-manager
- **主脚本：** [xiazheteng-node-manager.sh](https://github.com/xiazheteng8/xiazheteng-node-manager/blob/main/xiazheteng-node-manager.sh)
- **YouTube：** [瞎折腾吧](https://www.youtube.com/@xiazheteng8)
- **Telegram：** [t.me/xiazheteng8](https://t.me/xiazheteng8)

欢迎关注「瞎折腾吧」，获取更多 VPS 部署、节点配置、网络工具和技术折腾教程。

## 九、免责声明

本项目用于技术学习、服务器管理及网络配置研究。

使用者应自行遵守所在地法律法规、云服务商使用条款及相关网络管理规定。运行脚本前，请充分了解其操作内容，并自行评估服务器环境、网络安全和数据风险。

作者不对因错误配置、第三方服务故障、网络限制或用户自行修改脚本而造成的损失承担责任。

---

**项目名称：** 瞎折腾吧｜VPS 多协议节点管理器

**主脚本：** `xiazheteng-node-manager.sh`

**维护仓库：** [xiazheteng8/xiazheteng-node-manager](https://github.com/xiazheteng8/xiazheteng-node-manager)
