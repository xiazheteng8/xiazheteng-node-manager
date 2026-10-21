
# 瞎折腾吧｜VPS 多协议节点统一管理器

<p align="center">
  <a href="https://www.youtube.com/@xiazheteng8">YouTube：瞎折腾吧</a> ·
  <a href="https://t.me/xiazheteng8">Telegram：@xiazheteng8</a>
</p>

统一管理现有 Xray 无证书节点，并通过独立模块调用 yonggekkk/sing-box-yg 的 VPS 多协议部署功能。

## 项目结构

本项目采用统一菜单、独立内核的方式管理两套服务：

1. **Xray 无证书模块**：保护原有 REALITY、Shadowsocks 和订阅配置。
2. **Sing-box-yg 模块**：通过官方上游脚本管理五协议、证书及其上游版本提供的附加功能。

两种内核使用不同的配置文件、服务和节点输出方式，不会强行合并成一份 JSON。

## 功能说明

| 功能 | 管理方式 |
|---|---|
| 检查 Xray 配置 | 本管理器 |
| 备份现有 Xray 配置和订阅文件 | 本管理器 |
| 查看服务与端口状态 | 本管理器 |
| 恢复 Xray 配置备份 | 本管理器 |
| VLESS REALITY Vision | Sing-box-yg 上游模块 |
| VMess WS/TLS 或 Argo | Sing-box-yg 上游模块 |
| Hysteria 2 | Sing-box-yg 上游模块 |
| TUIC v5 | Sing-box-yg 上游模块 |
| AnyTLS | Sing-box-yg 上游模块 |
| 自签证书、ACME 证书 | 按上游版本提供的菜单操作 |
| 临时/固定 Argo | 按上游版本提供的菜单操作 |
| WARP/Psiphon 分流 | 仅在上游版本支持且正确配置时可用 |
| 跨内核订阅聚合 | 当前未实现 |

上游项目：<https://github.com/yonggekkk/sing-box-yg>

## 当前服务器的既有路径

| 项目 | 路径或服务 |
|---|---|
| Xray 程序 | `/usr/local/bin/xray` |
| Xray 无证书配置 | `/usr/local/etc/xray/node-manager-nocert.json` |
| Xray 无证书服务 | `xray-node-manager-nocert.service` |
| 原订阅文件 | `/var/lib/node-manager-nocert/subscription.txt` |
| 原订阅服务 | `node-manager-nocert-subscription.service` |
| 管理器目录 | `/opt/xiazheteng-node-manager` |
| 上游脚本缓存 | `/opt/xiazheteng-node-manager/upstream/sb.sh` |
| 备份目录 | `/root/node-manager-backups` |

## 安装

以 root 登录 VPS 后，将 `xiazheteng-node-manager.sh` 保存至：

```text
/root/xiazheteng-node-manager.sh
```

设置权限并启动：

```bash
chmod 700 /root/xiazheteng-node-manager.sh
bash /root/xiazheteng-node-manager.sh
```

## 菜单

| 编号 | 功能 |
|---|---|
| 1 | 启动勇哥 Sing-box 多协议模块 |
| 2 | 下载或更新上游脚本，不自动执行 |
| 3 | 检查现有无证书 Xray 配置 |
| 4 | 查看服务状态和端口监听 |
| 5 | 备份现有 Xray 配置及订阅文件 |
| 6 | 查看备份列表 |
| 7 | 恢复指定的 Xray 配置备份 |
| 8 | 查看订阅文件及服务信息 |
| 0 | 退出 |

## 有证书和无证书模式

证书及协议部署由 Sing-box-yg 上游脚本处理。请根据上游脚本实际显示的选项，选择无证书/自签证书或 ACME 证书方案。

如果需要使用已有证书，应先确认上游版本是否支持指定已有证书和私钥路径；不要直接假定它会自动复用系统中的证书。

## 端口与现有服务保护

现有服务器已使用部分常见端口，包括 Xray REALITY 的 TCP 443、Shadowsocks 的 TCP/UDP 8388、订阅服务的 TCP 18080，以及 Nginx 的 TCP 80。

部署新协议前应确认：

- 新服务的端口没有被现有服务占用。
- VPS 防火墙和云安全组已放行所需 TCP/UDP 端口。
- 证书申请方式不会与现有 Nginx、网站或邮件服务冲突。
- 上游脚本没有被配置为停止或覆盖现有 Xray 服务。

本管理器不会自动停止默认 `xray.service`，也不会自动改写 Nginx 配置。但上游脚本是独立安装程序，可能安装依赖、建立服务或调整系统设置；执行前仍须检查其菜单和影响范围。

## 备份与恢复

查看备份：

```bash
ls -lht /root/node-manager-backups
```

检查原有 Xray 配置：

```bash
/usr/local/bin/xray run -test \
  -config /usr/local/etc/xray/node-manager-nocert.json
```

检查原有服务：

```bash
systemctl status xray-node-manager-nocert.service --no-pager
```

注意：恢复 Xray 配置不会自动恢复所有其他系统状态，例如防火墙、上游 Sing-box 配置或证书。执行恢复后应再次检查配置与服务。

## 订阅

现有无证书订阅服务的 URL 形式为：

```text
http://服务器地址:订阅端口/订阅令牌
```

请以服务的实际环境变量和配置为准。订阅令牌属于敏感信息，不应提交到公开仓库。

Xray 和 Sing-box-yg 的订阅目前分别由各自模块管理。若要合并成一个跨内核订阅，需要另外实现协议识别、订阅格式转换、去重和更新机制；本管理器没有宣称已经实现该功能。

## 故障排查

Xray 服务状态：

```bash
systemctl status xray-node-manager-nocert.service --no-pager
```

Xray 日志：

```bash
journalctl -u xray-node-manager-nocert.service -n 100 --no-pager
```

订阅服务状态：

```bash
systemctl status node-manager-nocert-subscription.service --no-pager
```

订阅服务日志：

```bash
journalctl -u node-manager-nocert-subscription.service -n 100 --no-pager
```

端口监听：

```bash
ss -lntup
```

## 上游项目与许可证

- 上游脚本：<https://github.com/yonggekkk/sing-box-yg>
- 上游许可证、版权和使用条款：请以仓库中的 LICENSE 文件为准。
- 本管理器通过独立模块调用上游脚本，不代表上游作者对本项目提供支持。

## 频道

- YouTube：<https://www.youtube.com/@xiazheteng8>
- Telegram：<https://t.me/xiazheteng8>
