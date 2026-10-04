# Tunlet 入门指南

这份指南写给不熟悉命令行的人。你可以自己照着操作，也可以把其中的提示词交给 AI Agent。

## 开始前确认

Tunlet 需要以下条件：

- Apple 芯片 Mac
- macOS 26 或更高版本
- 可用的 aTrust 账号
- aTrust 服务器地址，也就是平时登录官方客户端时使用的地址
- 能接收短信验证码的手机

点开屏幕左上角的苹果菜单，选择“关于本机”，可以看到芯片和 macOS 版本。

Tunlet 还需要 [Apple Container](https://github.com/apple/container/releases/latest)。已经安装 Homebrew 的用户可以在终端运行：

```bash
brew install container
```

## 让 AI Agent 帮你安装

可以把下面这段话完整交给能够操作本机终端的 AI Agent：

```text
请帮我在这台 Mac 上安装并检查 Tunlet，项目地址是：
https://github.com/PiktCai/tunlet-mac

请按项目 README 的 one-liner 安装方式操作。开始前确认这是 Apple 芯片 Mac，系统为 macOS 26 或更高版本，并检查 Apple Container 是否已经安装。不要关闭或修改我现有的代理软件、系统代理和 Clash 配置。

需要输入 aTrust 服务器、账号、密码或短信验证码时，请暂停并让我自己输入，不要要求我把密码或验证码发到聊天里。安装后检查 tunlet status，但不要自行运行 reclaim 或 uninstall。最后告诉我如何把官方 Tunlet YAML 链接作为 Clash 配置订阅导入。
```

安装过程中如果 macOS 弹出权限或 Touch ID 窗口，需要由你本人确认。

## 自己安装

打开“终端”，复制下面这一整行，粘贴后按回车：

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/PiktCai/tunlet-mac/main/install.sh)"
```

安装器会把 `tunlet` 命令放到当前用户的应用目录。下载源码和构建镜像时产生的临时文件会自动删除，不会在“下载”文件夹留下仓库副本。

第一次安装可能需要一些时间。看到 `Tunlet is ready` 就表示安装完成。

## 连接

每次需要使用时，在终端运行：

```bash
tunlet start
```

按提示输入服务器地址、账号、密码和短信验证码。输入密码时终端不会显示字符，这是正常现象。

第一次登录成功后，可以选择把密码保存在 macOS 钥匙串：

- 选 1：以后每次读取密码时使用 Touch ID，推荐使用。
- 选 2：以后自动读取密码，不再确认。
- 选 3：不保存密码。

看到下面的信息后，隧道已经可以使用：

```text
Connected. SOCKS5 proxy: 127.0.0.1:11080
```

## 把配置作为 Clash 订阅导入

支持从 URL 导入 Clash 配置的客户端，可以直接订阅下面的地址：

```text
https://raw.githubusercontent.com/PiktCai/tunlet-mac/main/tunlet.yaml
```

如果 GitHub Raw 无法访问，可以改用 jsDelivr：

```text
https://cdn.jsdelivr.net/gh/PiktCai/tunlet-mac@main/tunlet.yaml
```

不同客户端的按钮名称可能是“配置”“Profiles”“订阅”或“从 URL 导入”。新建一个配置，名称填写 `Tunlet`，粘贴上面的地址并更新，然后选择这个配置。

这是一份独立的全局配置，不会和当前配置中的其他代理节点合并。请先运行 `tunlet start`，确认连接成功后再切换。切换后，原有代理不再生效，ChatGPT 或正在操作电脑的 AI Agent 可能会断开，因此最好让 Agent 完成安装后，由你自己切换配置。用完后先切回平时使用的 Clash 配置，再停止 Tunlet。

不支持 URL 导入的客户端仍可下载仓库中的 [tunlet.yaml](../tunlet.yaml)，再作为本地配置导入。

## 断开、更新和删除

用完后运行：

```bash
tunlet stop
```

查看当前状态：

```bash
tunlet status
```

更新程序时，重新运行安装 one-liner。账号设置和钥匙串密码会保留。

如果只是暂时需要腾出约 1.4 GB 的镜像空间，可以运行：

```bash
tunlet reclaim
```

这会保留程序、账号设置和钥匙串密码。下次使用前运行 `tunlet install` 恢复镜像。

完全卸载：

```bash
tunlet uninstall
```

## 只使用一次，不安装命令

这个方式适合熟悉 Git 和终端的用户。它不会把 `tunlet` 命令安装到用户目录，程序文件和本地状态都留在源码文件夹中。运行镜像仍由 Apple Container 保存，执行源码目录中的卸载命令后会一并删除。

```bash
git clone https://github.com/PiktCai/tunlet-mac.git
cd tunlet-mac
./tunlet setup
./tunlet start
```

用完后在源码目录运行：

```bash
./tunlet stop
./tunlet uninstall
```

确认清理完成后，可以删除 `tunlet-mac` 文件夹。不要同时使用长期安装模式和源码模式，它们会共用同一个运行镜像。

遇到安装失败、无法登录或目标网站打不开时，请查看[原理与排障](troubleshooting.md)。
