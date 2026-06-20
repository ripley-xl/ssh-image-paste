# 让本地截图穿过 SSH：一次复刻 cmux 粘贴体验的实战

本地开发时，截图粘给 Claude Code 很自然：截屏，`Cmd+V`，图片就进了对话。可是一进 SSH，这件小事就变难了。终端在本地，Claude Code 跑在远程；图片留在本地剪贴板，远程机器却什么也看不见。

我想要的体验很简单：在 macOS 截图，在 Warp 里连着 `ssh myserver`，打开远程 Claude Code，直接 `Cmd+V`。不用手动 `scp`，不用想文件名，也不用在本地和远程之间来回切。

最后可用的方案不是“同步远程剪贴板”，也不是某个神秘的 OSC 图片协议，而是一个更朴素的链路：

```text
本地图片剪贴板
  -> 本地落成临时图片文件
  -> 上传到所有活跃 SSH 远程
  -> 本地剪贴板替换成远程图片路径
  -> 在远程 Claude Code 粘贴路径
  -> Claude Code 把路径读成图片
```

这篇文章记录这个方案怎么来，哪里踩坑，以及为什么“无 GUI 的远程剪贴板”不是正确答案。

## 问题不在复制，而在机器边界

`Cmd+V` 失败时，Claude Code 会报：

```text
No image found in clipboard
```

这句话容易误导人。图片确实在剪贴板里，只是不在远程机器的剪贴板里。远程 Linux 没有桌面会话时，通常也没有 `DISPLAY`、`WAYLAND_DISPLAY`、`wl-copy`、`xclip`。这时“远程系统剪贴板”不是空的，而是根本不存在。

所以，给远程部署 daemon、试图写远程 GUI 剪贴板，只能算增强。它适合有桌面环境的远程机；对普通 SSH 主机，尤其是云机，它不是主路径。

主路径必须绕开远程 GUI 剪贴板。

## cmux 给出的线索：传路径，不传图片

一开始我怀疑 cmux 用了 OSC 52 或更特殊的终端协议。OSC 52 确实能走终端剪贴板，但它主要面向文本；图片剪贴板在不同终端里没有稳定通道。

看过 cmux 的实现后，答案清楚了：它没有把图片二进制塞进终端协议，而是先把图片变成文件。如果目标是远程 SSH，就上传文件，再把远程路径粘进终端。粘贴本身走 bracketed paste，也就是终端常见的：

```text
ESC[200~ ... ESC[201~
```

Claude Code 看到图片路径后，会自己读取文件，并把它变成图片附件。换句话说，关键不是“把图片送进终端”，而是“让 Claude Code 在它所在的机器上读到图片文件”。

这个思路很重要。它把问题从“跨机器同步图片剪贴板”降成了“跨机器传文件，再粘路径”。

## 独立工具的第一版

我把这个行为拆成一个独立小工具，叫 SSH Image Paste。它有两个入口：

- `ssh-image-paste`：手动上传当前剪贴板图片，打印远程路径。
- `ssh-image-paste-daemon`：后台监听 macOS 剪贴板，自动上传图片。

daemon 做几件事：

1. 监听 macOS `NSPasteboard`。
2. 发现图片或图片文件 URL 后，写成本地临时文件。
3. 扫描当前用户的 SSH 进程，找出带 TTY 的交互会话。
4. 用 `scp` 把图片上传到每台远程机器。
5. 远程路径固定为 `/tmp/ssh-image-paste-<hash>.png`。
6. 把本地剪贴板替换成这个远程路径。

这样，远程 Claude Code 不需要读远程 GUI 剪贴板。你按下 `Cmd+V` 时，它收到的是：

```text
/tmp/ssh-image-paste-06aa3f8739d084598bbc0c13.png
```

这个文件就在远程机器上，Claude Code 能直接读。

## 第一个坑：检测不到 Warp 里的 SSH

工具刚跑起来时，看似 daemon 没生效。实际上，图片已经在本地剪贴板里，却没有上传。

原因很小：macOS 的 `ps` 输出会给 `ucomm` 字段补空格，解析出来的进程名不是 `"ssh"`，而是 `" ssh             "`。检测器没做 trim，于是一个 SSH 会话也找不到。

修掉这个问题后，链路立刻跑通：

```text
本地复制图片
  -> 上传到 myserver
  -> 本地剪贴板变成 /tmp/ssh-image-paste-*.png
```

这个 bug 也提醒我：自动化工具不怕思路复杂，怕边界小而碎。进程表、TTY、SSH 参数、终端包装器，任何一个细节都可能让“看起来应该工作”的方案落空。

## 第二个坑：轮询有竞态

daemon 最初靠轮询剪贴板。间隔调到 `0.2s` 后已经很快，但仍有竞态：

1. 用户截图。
2. 用户马上在 Warp 里 `Cmd+V`。
3. Claude Code 先收到图片剪贴板。
4. daemon 还没来得及把剪贴板换成路径。

结果还是：

```text
No image found in clipboard
```

所以，要做到“无感”，光靠轮询不够。更好的方式是在终端前台按下 `Cmd+V` 时拦截这次粘贴：如果剪贴板里是图片，就先上传，改成路径，再把 `Cmd+V` 重放给终端。

这就是后来的 `--paste-intercept` 模式。

```bash
Scripts/install-launch-agent.sh '~/.local/bin/ssh-clipboard-image-remote.py' \
  --paste-intercept --no-remote-clipboard --interval 0.2 --verbose
```

它只在前台应用是 Warp、Wave、iTerm2、Terminal 或 Ghostty 时拦截，避免影响普通应用。

## 为什么需要 macOS 权限

拦截 `Cmd+V` 需要监听键盘事件，重放 `Cmd+V` 需要发送键盘事件。macOS 会把这两件事分别归到隐私权限里：

- 输入监控：监听按键。
- 辅助功能：发出合成按键。

没有这两个权限，event tap 创建不起来。daemon 会退回轮询模式：等剪贴板变成 `/tmp/ssh-image-paste-*.png` 后再粘贴。它能用，但不够无感。

这不是实现细节，而是产品边界。一个后台进程想替用户拦截粘贴，就必须经过系统授权。

## 为什么不用 TTY 注入

还有一条路看似更直接：往 SSH 对应的本地 TTY 写入 bracketed paste。macOS 有 `TIOCSTI`，理论上能模拟终端输入。

实测不行。后台进程不是这个终端的宿主，向 `/dev/ttysXXX` 注入输入会返回：

```text
Operation not permitted
```

cmux 能做得更自然，是因为它自己就是终端宿主。它握着 Ghostty surface，可以直接调用终端输入 API。独立 daemon 没有这层能力，只能走系统允许的通道：剪贴板、event tap、或未来的终端插件。

## 最终形态

现在这个工具有三层能力：

1. **基础模式**：监听剪贴板，上传图片，把本地剪贴板换成远程路径。
2. **拦截模式**：在终端里按 `Cmd+V` 时先上传，再重放粘贴，减少竞态。
3. **远程剪贴板模式**：如果远程有 GUI 环境，顺手写远程系统剪贴板；没有 GUI 时跳过。

对无 GUI SSH，核心能力是第一层和第二层。远程 GUI 剪贴板只是锦上添花。

## 这次实现给我的教训

第一，先分清图片在哪台机器上。很多“剪贴板同步”问题，本质上是进程和文件的机器边界没理清。

第二，不要把终端协议当魔法。OSC 52、bracketed paste、TTY 注入各有用途，但它们不能替代文件可达性。Claude Code 真正需要的是它能读取的图片文件。

第三，体验问题常常是时序问题。轮询能跑通功能，却不一定跑通体验。用户手快一点，竞态就会暴露。

第四，独立工具要承认系统边界。cmux 能直接喂 Ghostty surface，后台 daemon 不能。想复刻同样体验，就要换路：event tap、权限、明确的降级策略。

最后的结果很小：截图后按 `Cmd+V`，远程 Claude Code 能看到图片。但这件小事背后，有剪贴板、SSH、终端、macOS 权限和工具边界。把边界逐个拆开，方案反而简单了。
