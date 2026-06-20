# SSH Image Paste

Paste macOS screenshots and clipboard images into Claude Code over SSH.

SSH Image Paste 把 macOS 本地截图、复制的图片或图片文件粘到远程 SSH 会话里。它先把图片上传到远程主机，再把远程图片路径粘进终端，让远程 Claude Code 直接读取图片。

## 为什么做这个

Claude Code 在 SSH 里运行时，读的是远程机器。你在 macOS 截图后，图片还在本地剪贴板；远程机器通常没有 GUI 剪贴板，也看不到这张图片。所以直接 `Cmd+V` 常会得到：

```text
No image found in clipboard
```

这个工具解决的就是这条断层：本地有图，远程要读图，中间缺一个自动上传和粘贴路径的桥。

它适合这些场景：

- 在 Warp、Wave、iTerm2、Terminal 或 Ghostty 里 SSH 到远程主机，然后使用 Claude Code。
- 远程主机无 GUI、无 `DISPLAY`、无 `wl-copy` 或 `xclip`。
- 想把截图、设计稿、报错图直接交给远程 AI 编程工具，不想手动 `scp`。

目标体验：

1. 本地截图或复制图片。
2. 在 Warp、Wave、iTerm2、Terminal、Ghostty 里的远程 SSH 会话按 `Cmd+V`。
3. 远程 Claude Code 收到 `/tmp/ssh-image-paste-*.png` 路径，并把它当图片读取。

它不依赖远程 GUI 剪贴板。无 GUI 的云主机也能用。

## 原理

远程 Claude Code 需要读到远程机器上的图片文件。本工具做这几步：

```text
macOS 图片剪贴板
  -> 写成本地临时图片
  -> 扫描当前活跃 SSH 会话
  -> scp 上传到远程 /tmp/ssh-image-paste-*.png
  -> 把本地剪贴板换成远程路径
  -> 终端里粘贴路径
```

`--paste-intercept` 模式会拦截终端前台的 `Cmd+V`：先上传图片，再重放 `Cmd+V`。这样可以避免“用户按得太快，Claude Code 先读到图片剪贴板”的竞态。

## 编译

需要 macOS 和 SwiftPM。

```bash
git clone https://github.com/ripley-xl/ssh-image-paste.git
cd ssh-image-paste
swift test
swift build -c release
```

生成两个可执行文件：

```text
.build/release/ssh-image-paste
.build/release/ssh-image-paste-daemon
```

`ssh-image-paste` 是手动命令。

`ssh-image-paste-daemon` 是后台服务，日常用它。

## 本机安装

推荐安装为 LaunchAgent：

```bash
cd ssh-image-paste
Scripts/install-launch-agent.sh '~/.local/bin/ssh-clipboard-image-remote.py' \
  --paste-intercept --no-remote-clipboard --interval 0.2 --verbose
```

这条命令会：

1. 编译 release binary。
2. 写入 `~/Library/LaunchAgents/io.github.ripley-xl.ssh-image-paste-daemon.plist`。
3. 启动 `ssh-image-paste-daemon`。

当前 daemon 路径是：

```text
$HOME/code/ssh-image-paste/.build/release/ssh-image-paste-daemon
```

查看运行状态：

```bash
launchctl print gui/$(id -u)/io.github.ripley-xl.ssh-image-paste-daemon
```

看日志：

```bash
tail -f /tmp/io.github.ripley-xl.ssh-image-paste-daemon.err.log
```

## macOS 权限

如果启用 `--paste-intercept`，macOS 需要两个权限：

- 输入监控：监听 `Cmd+V`。
- 辅助功能：重放 `Cmd+V`。

在系统设置里添加这个文件：

```text
$HOME/code/ssh-image-paste/.build/release/ssh-image-paste-daemon
```

如果添加窗口看不到 `.build`，按 `Cmd+Shift+G`，粘贴上面的完整路径，再回车。

授权后重启 daemon：

```bash
launchctl kickstart -k gui/$(id -u)/io.github.ripley-xl.ssh-image-paste-daemon
```

日志里看到这行，说明拦截模式可用：

```text
paste intercept enabled for terminal apps
```

如果看到下面这行，说明权限还没给对：

```text
paste intercept unavailable; grant Accessibility/Input Monitoring if macOS prompts
```

此时仍可用轮询模式：截图后等约 1 秒，剪贴板会变成 `/tmp/ssh-image-paste-*.png`，再按 `Cmd+V`。

## 远程部署

无 GUI 远程不需要 helper。Claude Code 只要能读 `/tmp/ssh-image-paste-*.png` 就够了。

如果远程有桌面环境，想顺手写远程系统剪贴板，可以部署 helper：

```bash
for h in myserver staging box; do
  ssh "$h" 'mkdir -p ~/.local/bin ~/.ssh-image-paste && chmod 700 ~/.ssh-image-paste'
  scp Remote/ssh-clipboard-image-remote.py "$h:~/.local/bin/ssh-clipboard-image-remote.py"
  ssh "$h" 'chmod +x ~/.local/bin/ssh-clipboard-image-remote.py; python3 -m py_compile ~/.local/bin/ssh-clipboard-image-remote.py'
done
```

在有 user systemd 的远程上，可以把 helper 跑成用户服务。无 GUI 主机即使服务在，通常也没有 `wl-copy`、`xclip`、`DISPLAY` 或 `WAYLAND_DISPLAY`，所以远程剪贴板写入会跳过。这不影响 Claude Code 读图片路径。

## 日常使用

1. 本地截图，或复制一张图片。
2. 确认本地有活跃 SSH 会话，比如 Warp 里 `ssh myserver`。
3. 在远程 Claude Code 输入框按 `Cmd+V`。

成功时会粘贴类似路径：

```text
/tmp/ssh-image-paste-06aa3f8739d084598bbc0c13.png
```

Claude Code 会读取这个远程文件，并把它当作图片。

## 手动命令

如果不想跑 daemon，可以手动上传当前剪贴板图片：

```bash
.build/release/ssh-image-paste --tty /dev/ttys001 --copy-path --raw
```

也可以显式指定远程：

```bash
.build/release/ssh-image-paste --dest myserver --copy-path --raw
```

命令会上传图片，并把远程路径复制回本地剪贴板。

## 验证

复制一张图片后，检查本地剪贴板：

```bash
pbpaste
```

应输出：

```text
/tmp/ssh-image-paste-*.png
```

检查远程文件：

```bash
ssh myserver 'ls -lt /tmp/ssh-image-paste-* 2>/dev/null | head'
```

检查本地 daemon 日志：

```bash
tail -n 80 /tmp/io.github.ripley-xl.ssh-image-paste-daemon.err.log
```

常见成功日志：

```text
uploaded 1 file(s) to myserver via ttys001
copied remote path(s) to local clipboard for Claude Code
```

## 排障

### Claude Code 仍然报 `No image found in clipboard`

这说明 Claude Code 还在读远程 GUI 剪贴板，没有收到远程路径。

先看本地剪贴板：

```bash
pbpaste
```

如果不是 `/tmp/ssh-image-paste-*.png`，说明 daemon 还没处理完，或没检测到 SSH。

检查活跃 SSH：

```bash
ps -axo pid=,pgid=,tpgid=,tty=,ucomm=,command= | rg '[s]sh'
```

检查日志：

```bash
tail -n 120 /tmp/io.github.ripley-xl.ssh-image-paste-daemon.err.log
```

### `--paste-intercept` 没生效

先看日志：

```bash
tail -n 80 /tmp/io.github.ripley-xl.ssh-image-paste-daemon.err.log
```

如果看到：

```text
paste intercept unavailable
```

去系统设置给 `ssh-image-paste-daemon` 添加“输入监控”和“辅助功能”权限，然后重启 daemon。

### 远程 GUI 剪贴板写入失败

无 GUI 远程会失败，这是预期结果。推荐安装时加：

```bash
--no-remote-clipboard
```

Claude Code 路径模式不需要远程 GUI 剪贴板。

### TTY 注入失败

`--tty-inject` 会尝试往 `/dev/ttysXXX` 注入 bracketed paste。macOS 通常返回：

```text
Operation not permitted
```

这是系统限制。cmux 能直接喂 Ghostty surface，独立后台进程不能。日常不要依赖 `--tty-inject`。

## 卸载

```bash
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/io.github.ripley-xl.ssh-image-paste-daemon.plist
rm ~/Library/LaunchAgents/io.github.ripley-xl.ssh-image-paste-daemon.plist
```

远程 helper 可删：

```bash
for h in myserver staging box; do
  ssh "$h" 'rm -f ~/.local/bin/ssh-clipboard-image-remote.py'
done
```
