# aTrust Lite Mac

在 Apple Silicon Mac 上运行精简的 aTrust。连接成功后，本机开放一个 SOCKS5 代理，可供浏览器、系统代理或其他网络工具使用。

> 本仓库不包含深信服 aTrust 安装包、许可证、账号、密码或预构建镜像。请自行取得有权使用的官方安装包，并遵守所在机构的访问规定。

## 工作原理

```text
应用程序
    │
    ▼
SOCKS5 127.0.0.1:11080
    │
    ▼
Apple Container 中的 aTrust Lite
    │
    ▼
aTrust 隧道 → 受保护资源
```

镜像从官方 aTrust Linux ARM64 安装包中提取必要组件。Rust supervisor 负责登录、短信验证、隧道进程和 SOCKS5 服务，容器提供 TUN 网络环境。

## 适用环境

- Apple Silicon Mac
- macOS 26
- [Apple Container](https://github.com/apple/container)
- 官方 aTrust Linux ARM64 `.deb` 安装包
- 可用的 aTrust 账号

Intel Mac、Windows、Linux 主机和其他架构的安装包尚未验证。

## 安装

启动 Apple Container，然后构建本地镜像：

```bash
./scripts/build-apple-arm64.sh /path/to/aTrustInstaller_arm64.deb
```

默认镜像名为 `atrust-lite-runtime:local-arm64`。官方安装包只用于本地构建，不会复制到仓库中。

## 使用

双击 `启动aTrust.command`，按提示输入服务器地址、账号、密码和短信验证码。连接成功后，将需要访问受保护资源的程序设置为使用以下代理：

```text
类型：SOCKS5
地址：127.0.0.1
端口：11080
```

仓库中的 `atrust.yaml` 可直接导入兼容 Clash 配置格式的客户端。该配置使用 `MATCH` 规则，所有流量都会转发到 aTrust SOCKS5 出口。

断开连接时双击 `停止aTrust.command`，也可以直接运行脚本：

```bash
./scripts/apple-lite-start.sh
./scripts/apple-lite-stop.sh
```

## 安全说明

- 账号、密码和验证码不会写入项目配置。
- 临时凭据在 supervisor 读入后立即删除。
- SOCKS5 和辅助接口只映射到本机回环地址。
- 项目不绕过 MFA、授权或访问控制。

## 来源与许可

本项目基于 [HomoLand/atrust-lite-gateway](https://github.com/HomoLand/atrust-lite-gateway) 的 MIT 许可代码。`fake-getlogin` 兼容层参考了 [docker-easyconnect/docker-easyconnect](https://github.com/docker-easyconnect/docker-easyconnect) 的 WTFPL 实现，详见 [NOTICE.md](NOTICE.md)。

项目代码采用 [MIT License](LICENSE)。深信服 aTrust 不属于本项目，也不随仓库分发。
