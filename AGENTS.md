# 项目维护约定

- 目标环境仅为 Apple Silicon macOS 和 Apple Container。
- 脚本只负责 aTrust 运行时，不得自动修改系统代理或第三方代理客户端。
- 不得提交 aTrust 安装包、运行镜像、账号、密码、验证码、token、日志或 `.local/`。
- 不得把深信服官方下载地址硬编码进脚本；构建只接受用户本地提供的 ARM64 `.deb`。
- 保留 `HomoLand/atrust-lite-gateway` 的 MIT 版权声明和 `fake-getlogin` 的来源说明。
- 修改 shell 脚本后运行 `bash -n scripts/*.sh *.command`。
- 修改 supervisor 后在 Linux 上运行其 Rust 单元测试。
- 修改运行时或镜像构建逻辑后运行 `./scripts/test-apple-arm64-runtime.sh`。
- README 保持中文、简短，并与真实操作方式一致。
