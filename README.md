# Tunlet

在 Apple Silicon Mac 上运行轻量 aTrust 隧道。连接成功后，本机开放 SOCKS5 代理，供浏览器、代理客户端或其他程序访问受保护资源。

> 本项目不包含深信服 aTrust 安装包、许可证、账号、密码或预构建镜像。请确认所在机构允许使用相应客户端和网络服务。

## 原理

```text
应用程序 → SOCKS5 127.0.0.1:11080
                    ↓
          Apple Container 中的 Tunlet
                    ↓
             aTrust 隧道 → 受保护资源
```

Tunlet 从官方 Linux ARM64 安装包提取运行组件。Rust supervisor 负责登录、短信验证、隧道进程和 SOCKS5 服务，Apple Container 提供隔离的 Linux 与 TUN 网络环境。

## 环境

- Apple Silicon Mac
- macOS 26 或更高版本
- [Apple Container](https://github.com/apple/container/releases/latest)
- 可用的 aTrust 账号

Apple Container 也可以通过 Homebrew 安装：

```bash
brew install container
```

不熟悉命令行，或者准备交给 AI Agent 操作，可以直接阅读[一步步使用指南](docs/getting-started.md)。

## 安装

复制下面一行到终端：

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/PiktCai/tunlet-mac/main/install.sh)"
```

默认使用中文。需要英文界面时运行：

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/PiktCai/tunlet-mac/main/install.sh)" -- --lang en
```

安装器会把源码下载到临时目录，将程序安装到 `~/Library/Application Support/Tunlet`，并在 `~/.local/bin` 创建 `tunlet` 命令；结束后删除下载和构建临时文件，不保留仓库副本，也不需要 `sudo`。希望先审阅脚本时，可直接查看仓库中的 [install.sh](install.sh)。

安装程序可以从深信服官方 CDN 下载并校验已验证版本，也可以使用本地 ARM64 `.deb` 或包含该文件的 `.zip`。第一次构建需要一些时间；以后重复运行安装命令时，如镜像仍在，可以直接保留现有镜像。

也可以克隆仓库后安装：

```bash
git clone https://github.com/PiktCai/tunlet-mac.git
cd tunlet-mac
./tunlet install
```

重新运行 one-liner 即可更新程序。安装过程会编译一个小型钥匙串辅助程序；缺少 Swift 编译器时，隧道仍能使用，但密码需要手动输入。可运行 `xcode-select --install` 安装 Command Line Tools。

只想临时使用、不安装全局命令，可以在源码目录运行：

```bash
git clone https://github.com/PiktCai/tunlet-mac.git
cd tunlet-mac
./tunlet setup
./tunlet start
```

使用结束后运行 `./tunlet uninstall`，再删除源码目录。源码模式和长期安装模式使用同一个运行镜像，不建议同时使用。

### 安装包来源

优先使用所在机构的 aTrust 接入页面提供的 Linux、UOS 或 ARM64 客户端。如果接入页面没有提供，可以使用项目验证过的 [aTrust 2.5.16.20 ARM64 安装包](https://atrustcdn.sangfor.com/standard/linux/2.5.16.20/uos/arm64/aTrustInstaller_arm64.deb)：

```text
SHA-256: c8c0c0add77c21abb72ae912b1ac01c2cad6cf0fc439a4b64545100153b0cf31
大小：198207056 字节
```

不同服务端可能要求不同客户端版本。已验证版本无法登录时，应改用所在机构提供的安装包。

## 使用

```bash
tunlet start
tunlet status
tunlet stop
```

首次启动时按提示输入服务器、账号、密码和短信验证码。服务器可以输入完整 URL，也可以只输入域名；未写协议时会自动补全为 HTTPS，例如 `vpn.example.edu.cn` 会变成 `https://vpn.example.edu.cn`。服务器与账号保存在本机应用数据目录；短信验证码不会保存。

界面默认使用中文，可以随时切换并保存语言偏好：

```bash
tunlet language en
tunlet language zh
```

只想临时使用另一种语言，可以把 `--lang zh|en` 放在命令前，例如 `tunlet --lang en status`。连接后，将需要访问受保护资源的程序设置为：

```text
类型：SOCKS5
地址：127.0.0.1
端口：11080
```

兼容 Clash 配置格式的客户端可以把下面的地址作为远程配置或订阅导入：

```text
https://raw.githubusercontent.com/PiktCai/tunlet-mac/main/tunlet.yaml
```

GitHub Raw 无法访问时，可以改用 `https://cdn.jsdelivr.net/gh/PiktCai/tunlet-mac@main/tunlet.yaml`。客户端不支持 URL 导入时，再下载 [tunlet.yaml](tunlet.yaml) 作为本地配置。该配置使用 `MATCH` 规则转发全部流量，不会和原有代理节点合并。请先连接 Tunlet，再切换到这个配置。

### 密码与 Touch ID

第一次手动登录成功后，Tunlet 会询问是否把密码保存到 macOS 登录钥匙串：

- 默认模式每次读取时请求 Touch ID；不可用时回退到系统登录认证。
- 无感模式无需确认，需要用户明确选择。
- 也可以不保存，每次手动输入。

```bash
tunlet credentials status
tunlet credentials forget
```

## 空间管理

Tunlet 停止时会自动删除临时容器，因此不会长期留下约 1.5 GB 的“运行容器”。本机实测中，运行镜像的压缩数据约 100 MB，Apple Container 解包后的 Tunlet 镜像快照约 1.4 GB；Apple Container 自身的基础组件另占约 1.5 GB。实际大小会随运行时版本变化，可用 `container system df` 查看。

急需空间时，可以保留命令、服务器、账号和钥匙串密码，只移除 Tunlet 镜像及临时数据：

```bash
tunlet reclaim --dry-run
tunlet reclaim
```

下次使用前运行 `tunlet install` 重新构建镜像。平时无需手动清理；安装器会删除安装包、构建上下文、编译输出、builder 状态和本次新增的构建基础镜像。

## 卸载

```bash
tunlet uninstall --dry-run
tunlet uninstall
```

完整卸载会删除 Tunlet 命令、已安装程序、运行镜像、本地状态、钥匙串密码和临时文件。Apple Container 及其他项目的数据不会被删除。`--include-builder` 可以额外删除共享 builder，但可能影响其他项目，默认不使用。

## 镜像分发

Apple Container 支持标准 OCI 仓库。本项目不发布公共运行镜像，因为最终镜像包含 aTrust 闭源文件，目前没有取得公开再分发授权。有权在自己的设备间迁移时，可参考[镜像分发](docs/image-distribution.md)使用私有仓库。

## 安全与拓展

- 密码和验证码只通过临时文件传入容器，读取后立即删除。
- 保存的密码位于 macOS 钥匙串，默认读取前需要 Touch ID 或系统认证。
- SOCKS5 和辅助接口只映射到本机回环地址。
- 项目不绕过 MFA、授权或访问控制。

Tunlet 当前只支持 aTrust。这种“容器内运行厂商 Linux 客户端、宿主机使用本地 SOCKS5”的结构也可能适用于其他企业 VPN 或零信任客户端，但需要重新验证安装包、无界面认证、TUN 网络能力与许可条件。感兴趣的开发者可以 fork 后参考[移植思路](docs/porting.md)自行适配；这不是兼容承诺或开发路线图。

遇到问题请参阅[原理与排障](docs/troubleshooting.md)。项目基于 [HomoLand/atrust-lite-gateway](https://github.com/HomoLand/atrust-lite-gateway) 的 MIT 许可代码，并参考 [docker-easyconnect/docker-easyconnect](https://github.com/docker-easyconnect/docker-easyconnect) 的 `fake-getlogin` 实现，详见 [NOTICE.md](NOTICE.md)。项目代码采用 [MIT License](LICENSE)，深信服 aTrust 不随仓库分发。
