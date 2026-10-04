# 移植思路

Tunlet 当前只支持 Apple Silicon Mac、Apple Container 和 aTrust。下面描述的是可供 fork 复用的设计思路，不是兼容列表或开发路线图。

## 可以复用的部分

Tunlet 把厂商客户端放进独立的 Linux 环境，在容器内建立 TUN 隧道，再向宿主机提供只监听回环地址的 SOCKS5 代理。这个模式并不专属于 aTrust，可复用的部分包括：

- Apple Container 的镜像构建和生命周期管理
- 容器所需的网络能力、端口映射和凭据临时传递
- `install`、`start`、`status`、`stop` 和 `uninstall` 命令结构
- 宿主机应用通过本地 SOCKS5 使用远程网络的方式

## 必须重写的部分

不同厂商的安装包、认证协议和隧道进程没有统一接口。移植到另一个客户端时，至少需要替换：

- `scripts/init-runtime.sh`：提取安装包并整理运行依赖
- `scripts/supervisor.rs`：登录、MFA、进程管理和连接状态
- `scripts/Containerfile`：运行库、文件布局和启动入口
- `scripts/test-runtime.sh`：针对目标客户端的冒烟测试

适配前应确认目标客户端具备可用的 Linux 构建、能在无桌面环境完成认证、允许创建 TUN 或等价网络接口，并且许可条款允许本地提取和运行。缺少其中任何一项，都可能需要完全不同的实现。

## 飞连及其他客户端

[飞连官方产品页](https://www.volcengine.com/product/feilian)列出了 Linux 客户端，因此从平台形态上存在研究空间。但公开信息不足以确认其 CPU 架构、无界面认证接口、容器内网络能力和私有化版本差异，不能据此判断它可以直接套用 Tunlet。

有兴趣的开发者可以 fork 本项目，用所在机构提供的合法安装包验证上述条件，并为目标客户端建立独立的提取器和 supervisor。建议在 fork 中使用新的项目名，不要把多个厂商协议混入同一个运行镜像。

## 其他宿主系统

Tunlet 使用的 `container` CLI 官方支持 Apple Silicon 与 macOS 26 及更高版本，参见 [Apple Container 要求](https://github.com/apple/container/blob/main/README.md#requirements)。将同一思路带到 Linux 或 Windows，需要改用其他容器或虚拟化运行时，并重新处理 TUN、路由、DNS、端口映射和权限模型；这属于移植工程，而不是修改一个配置项。

## 安全与许可边界

- 不绕过 MFA、终端合规检查或访问控制
- 不提交或公开分发厂商安装包及预构建运行镜像
- 凭据只通过临时文件或等价的短期通道传入运行环境
- 本地代理默认只监听回环地址
