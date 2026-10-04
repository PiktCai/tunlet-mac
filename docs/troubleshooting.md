# 原理与排障

## 运行结构

Apple Container 提供 Linux ARM64 运行环境和 TUN 网络能力。Rust supervisor 调用 aTrust SDK，管理登录、短信验证、Core、Xtunnel 和 SOCKS5 服务。应用程序通过 `127.0.0.1:11080` 进入隧道。

SOCKS5 只在隧道连接成功后可用。停止脚本会通知 supervisor 断开连接，再停止容器。

## 镜像构建

构建脚本从官方 ARM64 `.deb` 中提取运行文件，并完成以下处理：

- 移除桌面 UI、Electron 资源和无关组件
- 补齐 Linux 动态库
- 使用系统 `libstdc++`
- 加入 `fake-getlogin` 兼容层
- 编译 Rust supervisor

官方安装包只作为本地构建输入，不会进入 Git 仓库或生成的源码发行包。

## 本机端口

| 地址 | 用途 |
| --- | --- |
| `127.0.0.1:11080` | SOCKS5 代理 |
| `127.0.0.1:54680` | 启停脚本调用的辅助接口 |

## 常见问题

### 安装包校验失败

自动下载使用固定版本和 SHA-256 校验值。校验失败时文件会被删除，不会继续构建。可以稍后重试，或从所在机构的 aTrust 接入页面下载 ARM64 安装包，再选择本地文件安装。

本地安装包可以是 `.deb`，也可以是包含 `aTrustInstaller_arm64.deb` 的 `.zip`。

### 找不到 `container`

确认 Apple Container 已安装：

```bash
container --version
container system status
```

### 找不到镜像

长期安装的用户运行：

```bash
tunlet install
```

源码模式的用户在仓库目录运行：

```bash
./tunlet setup
```

### 登录成功但无法访问目标

确认目标程序使用 SOCKS5 代理 `127.0.0.1:11080`，并检查目标资源是否在当前账号的授权范围内。可以直接测试代理：

```bash
curl --socks5-hostname 127.0.0.1:11080 -I https://example.com
```

### 没有钥匙串或 Touch ID 功能

安装时会使用系统 Swift 编译器构建本机钥匙串辅助程序。如果安装输出提示找不到 Swift，可以安装 Command Line Tools 后重新运行安装：

```bash
xcode-select --install
tunlet install
```

通过 `tunlet credentials status` 检查当前账号是否保存了密码。Touch ID 被取消、锁定或不可用时，Tunlet 会回退到手动输入密码；不会绕过系统认证。

### Apple Container 占用空间较大

查看 Apple Container 的磁盘占用：

```bash
container system df
```

Tunlet 使用 `container run --rm`，停止后不会保留运行容器。本机实测中，OCI 压缩数据约 100 MB，解包后的 Tunlet 镜像快照约 1.4 GB；Apple Container 的基础组件另占约 1.5 GB。实际大小随 Apple Container 和 aTrust 版本变化，不能只按压缩镜像估算。

只想临时腾出 Tunlet 镜像空间，同时保留命令、账号设置和钥匙串密码：

```bash
tunlet reclaim --dry-run
tunlet reclaim
```

下次使用前运行 `tunlet install` 重新构建镜像。不使用时，`tunlet stop` 会停止容器，并在没有其他运行容器时关闭 Apple Container 后台服务。

完整删除本项目时，可以运行 `tunlet uninstall`。该命令会删除已安装命令、程序、运行数据和钥匙串密码，但不会卸载 Apple Container，也不会清理其他项目的容器或镜像。

## 已知限制

- 只验证了 Apple Silicon 和 ARM64 aTrust 安装包。
- 认证流程可能因服务端配置不同而变化。
- aTrust 升级后可能需要重新验证兼容性。
- SOCKS5 不支持 UDP 转发。
