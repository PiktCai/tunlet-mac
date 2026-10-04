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

使用官方 ARM64 `.deb` 构建镜像：

```bash
./scripts/build-image.sh /path/to/aTrustInstaller_arm64.deb
```

### 登录成功但无法访问目标

确认目标程序使用 SOCKS5 代理 `127.0.0.1:11080`，并检查目标资源是否在当前账号的授权范围内。可以直接测试代理：

```bash
curl --socks5-hostname 127.0.0.1:11080 -I https://example.com
```

### Apple Container 占用空间较大

查看本地镜像和构建器状态：

```bash
container image list
container builder status
```

Apple Container 的虚拟机、基础镜像和构建缓存会占用额外空间。清理前应确认其他项目不再使用相关数据。

本项目生成的 OCI 镜像压缩后约 95 MB。Apple Container 1.5.0 会为运行镜像、`vminit` 和内部 builder shim 创建独立磁盘快照，首次构建后的实际占用可能在 3 GB 以上。这部分占用不能直接按压缩镜像大小估算。

不用时可以关闭后台服务，释放运行内存：

```bash
container system stop
```

删除 `tunlet-runtime:local-arm64` 会释放镜像磁盘空间，但下次使用前必须重新构建或从私有仓库拉取。

完整删除本项目的运行数据时，可以运行 `./tunlet uninstall`。该命令不会卸载 Apple Container，也不会清理其他项目的容器或镜像。

## 已知限制

- 只验证了 Apple Silicon 和 ARM64 aTrust 安装包。
- 认证流程可能因服务端配置不同而变化。
- aTrust 升级后可能需要重新验证兼容性。
- SOCKS5 不支持 UDP 转发。
