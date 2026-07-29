# REALITY One-key

面向 Debian、Ubuntu 和 Alpine Linux 的交互式 Xray REALITY 一键管理脚本。支持
AMD64（x86_64）和 ARM64（aarch64），包含安装、自定义配置、节点查询、内核更新、
状态检查以及完全卸载。

## 支持范围

| 系统 | 初始化系统 | AMD64 | ARM64 |
|---|---|---:|---:|
| Debian 11/12/13 | systemd | ✅ | ✅ |
| Ubuntu 20.04+ | systemd | ✅ | ✅ |
| Alpine 3.18+ | OpenRC | ✅ | ✅ |

脚本使用 VLESS + TCP + REALITY + `xtls-rprx-vision`，Xray 二进制取自
[XTLS/Xray-core](https://github.com/XTLS/Xray-core) 官方 Release。

## 快速使用

登录服务器后执行：

```bash
curl -fsSL https://raw.githubusercontent.com/colaxr/reality-onekey/main/install.sh | sudo bash
```

也可以直接下载管理脚本：

```bash
curl -fLo /usr/local/bin/reality \
  https://raw.githubusercontent.com/colaxr/reality-onekey/main/reality.sh
chmod +x /usr/local/bin/reality
sudo reality
```

## 命令

```text
sudo reality install          # 安装或重新生成节点配置
sudo reality edit             # 修改现有节点配置并保留 REALITY 密钥
sudo reality show             # 查询节点参数和 VLESS 分享链接
sudo reality status           # 查看服务状态
sudo reality update           # 更新至最新版 Xray
sudo reality self-update      # 更新管理脚本并重新打开菜单
sudo reality remove-node      # 删除节点，保留 Xray 和管理命令
sudo reality uninstall        # 交互式完全卸载
sudo reality uninstall --yes  # 无确认完全卸载
sudo reality                  # 打开交互菜单
x                             # 快捷呼出交互菜单
```

安装时可自定义：

- 监听端口；
- REALITY 伪装域名（SNI）；
- REALITY 目标地址（target）；
- 分享链接中的服务器公网 IP 或域名。

UUID、X25519 密钥和 Short ID 会使用 Xray/OpenSSL 安全生成。客户端信息保存在
`/etc/reality-onekey/node.env`，权限为 `600`；服务端配置保存在
`/etc/reality-onekey/config.json`。

## 使用前须知

1. 使用一台拥有公网 IP 的 VPS，并以 root 或 sudo 运行。
2. 在云厂商安全组和系统防火墙中放行所选 TCP 端口。
3. 伪装域名应支持 TLS 1.3、可从服务器访问，且通常不要填写自己的域名。
4. 请遵守服务器所在地法律法规及服务商条款。
5. 重新安装会生成新的 UUID 和密钥，旧节点链接随即失效。

## 删除节点与完全卸载

“删除节点”会停止并删除服务、REALITY 服务端配置、节点参数、PID 和相关日志，但
保留 Xray 二进制、Geo 数据及 `reality`、`x` 管理命令。“完全卸载”还会删除
Xray、Geo 数据、管理脚本与 `x` 快捷命令，并立即退出菜单。脚本不会修改云安全
组，也不会删除系统中原有的 curl、unzip、OpenSSL 等公共依赖。

## 安全说明

- 不通过第三方服务上传私钥或配置；
- Xray 以 `nobody` 用户运行，并仅授予绑定低端口所需的能力；
- systemd 服务启用 `NoNewPrivileges`；
- 配置文件仅 root 可读；
- 所有下载均通过 HTTPS 获取。

生产环境可进一步固定 Release 版本并校验官方 SHA256 校验和。

## License

[MIT](LICENSE)
