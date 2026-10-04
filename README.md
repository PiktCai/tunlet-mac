# Tunlet

在 Apple Silicon Mac 上运行轻量 aTrust 隧道。连接成功后，本机开放一个 SOCKS5 代理，可供浏览器、系统代理或其他网络工具使用。

> 本仓库不包含深信服 aTrust 安装包、许可证、账号、密码或预构建镜像。请自行确认所在机构允许使用相应客户端和网络服务。

## 工作原理

```text
应用程序
    │
    ▼
SOCKS5 127.0.0.1:11080
    │
    ▼
Apple Container 中的 Tunlet
    │
    ▼
aTrust 隧道 → 受保护资源
```

镜像从官方 aTrust Linux ARM64 安装包中提取必要组件。Rust supervisor 负责登录、短信验证、隧道进程和 SOCKS5 服务，Apple Container 提供 TUN 网络环境。

## 适用环境

- Apple Silicon Mac
- macOS 26
- 可用的 aTrust 账号

Intel Mac、Windows、Linux 主机和其他架构的安装包尚未验证。

## 快速安装

先安装 [Apple Container](https://github.com/apple/container/releases/latest)，也可以通过 Homebrew 安装：

```bash
brew install container
```

下载本仓库，在终端进入项目目录后运行：

```bash
./tunlet install
```

安装程序提供两种方式：

- 从深信服官方 CDN 下载并校验已验证版本
- 使用本地 ARM64 `.deb` 或包含该文件的 `.zip`

安装包只用于本地构建，完成后会自动删除临时文件。

## 安装包从哪里获取

优先使用所在机构的 aTrust 接入页面提供的客户端版本。用浏览器打开平时登录 aTrust 的地址，在客户端下载页面查找 Linux、UOS 或 ARM64 版本。

如果接入页面没有提供 ARM64 包，可以使用本项目验证过的 [aTrust 2.5.16.20 ARM64 安装包](https://atrustcdn.sangfor.com/standard/linux/2.5.16.20/uos/arm64/aTrustInstaller_arm64.deb)。文件由深信服官方 CDN 提供：

```text
SHA-256: c8c0c0add77c21abb72ae912b1ac01c2cad6cf0fc439a4b64545100153b0cf31
大小：198207056 字节
```

不同服务端可能要求不同客户端版本。已验证版本无法登录时，应改用所在机构提供的安装包。

## 使用

运行 `./tunlet start`，按提示输入服务器地址、账号、密码和短信验证码。服务器地址和账号会保存在本机 `.local/` 目录，密码和验证码不会保存。

连接成功后，将需要访问受保护资源的程序设置为：

```text
类型：SOCKS5
地址：127.0.0.1
端口：11080
```

`tunlet.yaml` 可导入兼容 Clash 配置格式的客户端。该配置使用 `MATCH` 规则，所有流量都会转发到 aTrust 出口。

常用命令如下：

```bash
./tunlet start
./tunlet status
./tunlet stop
```

遇到连接或构建问题时，参阅[原理与排障](docs/troubleshooting.md)。

## 删除

运行 `./tunlet uninstall`，确认后会删除本项目的容器、镜像、本地账号记录和遗留临时文件。项目源码和 Apple Container 程序会保留，其他容器及镜像不受影响。

需要先查看清理范围，或同时删除 Apple Container 的共享构建器缓存时，可以使用：

```bash
./tunlet uninstall --dry-run
./tunlet uninstall --include-builder
```

共享构建器可能也被其他项目使用，因此默认不会删除。

## 镜像仓库

Apple Container 使用标准 OCI 镜像，可以通过 Docker Hub、GitHub Container Registry 等仓库推送和拉取。本项目不发布公共运行镜像，因为其中包含 aTrust 闭源文件，目前没有取得公开再分发授权。

有权在自己的设备间复制镜像时，可以使用私有仓库，命令见[镜像分发](docs/image-distribution.md)。

## 安全说明

- 密码和验证码只通过临时文件传入容器，supervisor 读入后立即删除。
- SOCKS5 和辅助接口只映射到本机回环地址。
- 项目不绕过 MFA、授权或访问控制。
- aTrust 安装包和构建结果不进入 Git 仓库。

## 拓展思路

Tunlet 当前只支持 Apple Silicon Mac、Apple Container 和 aTrust。它采用“容器内运行厂商 Linux 客户端，宿主机通过本地 SOCKS5 使用隧道”的结构，具备移植到其他企业 VPN 或零信任客户端的可能性，但每个目标都需要重新验证安装包架构、无界面认证、TUN 网络能力和许可条件。

飞连官方提供 Linux 客户端，但公开信息还不足以判断能否直接在 Apple Container 中运行。感兴趣的开发者可以 fork 后按[移植思路](docs/porting.md)自行验证；这不是本项目的支持承诺或开发路线图。

## 来源与许可

本项目基于 [HomoLand/atrust-lite-gateway](https://github.com/HomoLand/atrust-lite-gateway) 的 MIT 许可代码。`fake-getlogin` 兼容层参考了 [docker-easyconnect/docker-easyconnect](https://github.com/docker-easyconnect/docker-easyconnect) 的 WTFPL 实现，详见 [NOTICE.md](NOTICE.md)。

项目代码采用 [MIT License](LICENSE)。深信服 aTrust 不属于本项目，也不随仓库分发。
