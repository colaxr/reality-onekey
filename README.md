# REALITY / Shadowsocks One-key

面向 Debian、Ubuntu 和 Alpine Linux 的交互式 Xray 节点管理脚本。支持
AMD64（x86_64）和 ARM64（aarch64），包含安装、自定义配置、节点查询、内核更新、
状态检查以及完全卸载。

## 支持范围

安装/重新配置时会复用可运行的 Xray，依赖齐全则跳过软件包管理器；缺少依赖时仅安装缺失项。Debian 安装阶段禁用 APT 二进制缓存、翻译索引和推荐包，减少开销。这不保证 64 MB 内存环境一定可安装或稳定运行，也不会自动创建 Swap。

下载解压及内核更新备份使用 `/var/tmp`，避免常见的 `/tmp` 内存盘占用；若 `/var/tmp` 本身也挂载在内存盘，仍会消耗内存，需要保证该位置有足够空间。

安装、修改及更新后会检查服务 PID 和全部节点监听，REALITY 检查 TCP，Shadowsocks 同时检查 TCP 和 UDP，要求连续三次通过才报告成功。OpenRC 后台进程立即退出会被检测到；修改配置或更新失败会尝试回滚。此检查不代表公网连通性测试。Xray 升级/重装仍使用菜单 5。

| 系统 | 初始化系统 | AMD64 | ARM64 |
|---|---|---:|---:|
| Debian 11/12/13 | systemd | ✅ | ✅ |
| Ubuntu 20.04+ | systemd | ✅ | ✅ |
| Alpine 3.18+ | OpenRC | ✅ | ✅ |

脚本支持 VLESS + TCP + REALITY + `xtls-rprx-vision`，以及原生 TCP + UDP 的 Shadowsocks。两种节点可以单独安装，也可以共用一个 Xray 服务同时运行，但必须使用不同端口。Xray 二进制取自
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
sudo reality install          # 选择安装/重新配置 REALITY 或 SS
sudo reality install-reality  # 直接安装/重新配置 REALITY
sudo reality install-ss       # 直接安装/重新配置 Shadowsocks
sudo reality edit             # 选择协议并修改节点
sudo reality show             # 选择协议并查询分享链接
sudo reality status           # 查看服务状态
sudo reality update           # 查询当前版本并选择 Xray 更新版本
sudo reality self-update      # 更新管理脚本并重新打开菜单
sudo reality remove-node      # 选择协议删除节点，保留其他节点
sudo reality uninstall        # 交互式完全卸载
sudo reality uninstall --yes  # 无确认完全卸载
sudo reality                  # 打开交互菜单
x                             # 快捷呼出交互菜单
```

进入主菜单的“1. 安装/重新配置”后，再选择 `REALITY` 或 `Shadowsocks（SS）`。安装 REALITY 时可自定义：

- 监听端口；
- REALITY 伪装域名（SNI）；
- REALITY 目标地址（target）；
- 分享链接中的服务器公网 IP 或域名。
- 客户端 uTLS 指纹（`fp`，默认 `chrome`）。
- 节点显示名称（支持中文和空格，并自动进行 URL 编码）。
- XUDP/UDP 支持（默认开启，分享链接自动加入 `packetEncoding=xudp`）。
- REALITY 最低客户端版本固定为 `1.0.0`，更新 Xray 时会自动迁移已有配置。

UUID、X25519 密钥和 Short ID 会使用 Xray/OpenSSL 安全生成。客户端信息保存在
`/etc/reality-onekey/node.env`，权限为 `600`；服务端配置保存在
`/etc/reality-onekey/config.json`。

安装 Shadowsocks 时可自定义服务器地址、端口、密码、节点名称和加密方式。支持
`aes-256-gcm`（默认）、`aes-128-gcm`、`chacha20-ietf-poly1305` 和
`xchacha20-ietf-poly1305`，服务端固定同时启用 TCP 和原生 UDP，并生成标准 `ss://`
分享链接。需要在云安全组和系统防火墙中同时放行所选端口的 TCP 与 UDP。SS 参数保存
在 `/etc/reality-onekey/ss.env`；密码经过 Base64 编码后落盘，文件权限为 `600`。
Xray v26.7.28 会提示传统 Shadowsocks 已弃用、未来可能移除；本功能目前可用，但后续
升级 Xray 前应先确认目标版本仍支持这些加密方式。

## 使用前须知

1. 使用一台拥有公网 IP 的 VPS，并以 root 或 sudo 运行。
2. REALITY 放行所选 TCP 端口；Shadowsocks 同时放行所选 TCP 和 UDP 端口。
3. 伪装域名应支持 TLS 1.3、可从服务器访问，且通常不要填写自己的域名。
4. 请遵守服务器所在地法律法规及服务商条款。
5. 重新安装 REALITY 会生成新的 UUID 和密钥；重新安装 SS 会替换密码，旧链接随即失效。
6. 两种节点共存时必须使用不同端口；安装、修改或删除一种协议不会覆盖另一种。

## 删除节点与完全卸载

“删除节点”会先选择协议，只删除对应节点并保留另一种协议；删除最后一个节点时才移除
共用服务。Xray 二进制、Geo 数据及 `reality`、`x` 管理命令仍会保留。“完全卸载”
会删除两种节点、Xray、Geo 数据、管理脚本与 `x` 快捷命令，并立即退出菜单。脚本不会
修改云安全组，也不会删除系统中原有的 curl、unzip、OpenSSL 等公共依赖。

## 安全说明

- 不通过第三方服务上传私钥或配置；
- Xray 以 `nobody` 用户运行，并仅授予绑定低端口所需的能力；
- systemd 服务启用 `NoNewPrivileges`；
- 节点参数仅 root 可读；服务端配置仅 root 和 Xray 服务账户可读；
- 所有下载均通过 HTTPS 获取。

生产环境可进一步固定 Release 版本并校验官方 SHA256 校验和。

## License

[MIT](LICENSE)
