# 项目维护约定

- 目标环境仅为 Apple Silicon macOS 和 Apple Container。
- 项目名、命令、镜像、容器、运行目录和临时文件前缀统一使用 `Tunlet` 或 `tunlet`。
- 脚本只负责 aTrust 运行时，不得自动修改系统代理或第三方代理客户端。
- 钥匙串密码只由 `tunlet-credentials` 访问，服务名固定为 `io.github.piktcai.tunlet.credentials`；密码不得进入命令行参数、日志或项目文件。
- 默认凭据模式必须在每次读取前请求 Touch ID；无感模式只能由用户明确选择。
- 当前支持范围仅限 aTrust；`docs/porting.md` 只描述 fork 思路，不代表兼容承诺或路线图。
- 不得提交 aTrust 安装包、运行镜像、账号、密码、验证码、token、日志或 `.local/`。
- 官方下载地址只放在安装入口中，并同时固定版本、大小和 SHA-256；构建脚本继续只接受本地 ARM64 `.deb`。
- 保留 `HomoLand/atrust-lite-gateway` 的 MIT 版权声明和 `fake-getlogin` 的来源说明。
- 修改 shell 脚本后运行 `bash -n tunlet scripts/*.sh`。
- 修改安装流程后同时验证官方包的版本、下载地址、大小和 SHA-256。
- 卸载脚本默认只能删除本项目的容器、镜像和本地状态；共享构建器必须由用户显式选择。
- 修改 supervisor 后在 Linux 上运行其 Rust 单元测试。
- 修改钥匙串辅助程序后在 macOS 上编译并验证临时凭据的保存、认证读取和删除。
- 修改运行时或镜像构建逻辑后运行 `./scripts/test-runtime.sh`。
- README 保持中文、简短，并与真实操作方式一致。
