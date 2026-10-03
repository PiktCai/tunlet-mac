# aTrust Lite Mac

在 Apple Silicon Mac 上按需运行精简的 aTrust，并把校园网连接作为一个本机 SOCKS5 出口交给 FlClash 使用。

本项目适合“偶尔访问校园内网、数据库或校内授权资源”的场景：平时不运行；需要时双击启动、在 FlClash 中切换到“校园网”配置；用完后切回日常配置并停止。

> 本仓库不包含深信服 aTrust 安装包、许可证、账号、密码或预构建镜像。请只在你有权使用的校园网或机构网络中使用。

## 原理

```text
浏览器 / 应用
      │
      ▼
FlClash「校园网」配置（全局转发）
      │  SOCKS5 127.0.0.1:11080
      ▼
Apple Container 中的 aTrust Lite
      │
      ▼
aTrust 隧道 → 校园网资源
```

容器只保留 aTrust 登录、隧道和转发所需组件。启动脚本临时读取账号和密码，登录后立即删除临时凭据文件；FlClash 只负责把流量交给本机 SOCKS5 端口，不需要独立 Chrome，也不会改动当前系统代理设置。

更详细的实现和已知限制见 [原理与排障](docs/原理与排障.md)。

## 适用环境

- Apple Silicon Mac（M1 及以后）
- macOS 26（当前验证环境）
- Apple Container 已安装并可运行
- FlClash 已安装
- 能合法取得机构提供的 aTrust Linux ARM64 `.deb` 安装包
- 已确认同一账号可通过官方 aTrust 客户端登录

目前没有验证 Intel Mac、Windows、Linux 主机或非 ARM64 的 aTrust 安装包。

## 首次准备

1. 安装并启动 [Apple Container](https://github.com/apple/container)。
2. 准备官方 aTrust Linux ARM64 安装包。
3. 在终端进入本仓库，构建本地镜像：

```bash
./scripts/build-apple-arm64.sh /path/to/aTrustInstaller_arm64.deb
```

4. 在 FlClash 中导入根目录的 `校园网.yaml`。

构建完成后，官方安装包不会留在仓库中。镜像保存在 Apple Container 的本地镜像库里，默认名称为 `atrust-lite-runtime:local-arm64`。

## 日常使用

1. 双击 `启动校园网.command`，输入 aTrust 地址、账号、密码和短信验证码。
2. 看到“连接成功”后，在 FlClash 中切换到 `校园网.yaml`。
3. 正常访问校内网站或数据库。
4. 用完先把 FlClash 切回原来的日常配置，再双击 `停止校园网.command`。

`校园网.yaml` 使用 `MATCH` 规则，因此选中后所有经过 FlClash 的流量都会走校园网出口。这正适合临时专用，但不建议长期开着。

## 常用命令

```bash
# 构建镜像
./scripts/build-apple-arm64.sh /path/to/aTrustInstaller_arm64.deb

# 启动并登录
./scripts/apple-lite-start.sh

# 停止
./scripts/apple-lite-stop.sh

# 验证镜像内的 aTrust Core 能启动
./scripts/test-apple-arm64-runtime.sh
```

如需使用其他 aTrust 地址，可以在启动时直接输入；武汉大学地址 `https://vpn.whu.edu.cn` 只是默认值。

## 安全与边界

- 账号、密码和验证码不会提交到 Git，也不会写入项目配置。
- 临时凭据在 supervisor 读入后立即删除；停止时会清理本地运行状态。
- SOCKS5 和辅助接口只映射到 `127.0.0.1`，不会直接暴露给局域网。
- 本项目不绕过 MFA、授权或访问控制。
- aTrust 是第三方闭源软件；升级 macOS、Apple Container 或 aTrust 后可能需要重新验证。

## 来源与许可

本项目是在 [HomoLand/atrust-lite-gateway](https://github.com/HomoLand/atrust-lite-gateway) 的 MIT 许可代码基础上，整理出的 macOS Apple Silicon 专用方案；`fake-getlogin` 兼容层参考了 [docker-easyconnect/docker-easyconnect](https://github.com/docker-easyconnect/docker-easyconnect) 的 WTFPL 实现。详见 [NOTICE.md](NOTICE.md)。

项目代码采用 [MIT License](LICENSE)。深信服 aTrust 本身不属于本项目，也不随仓库分发。
