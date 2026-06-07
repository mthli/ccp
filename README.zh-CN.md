# ccp

[English](README.md) · [繁體中文](README.zh-TW.md) · [日本語](README.ja.md) · [한국어](README.ko.md)

无需 headless 模式的 Claude Code headless 自动化 👀

## 这是什么

`ccp` 像 `claude -p` 一样运行 Claude Code（喂入一个 prompt，从 stdout 取回最终答案），但**计费走你的订阅额度，而非 Agent SDK 额度池**。

它的做法是在一个分离的 [tmux](https://github.com/tmux/tmux) 会话中驱动一个真实的*交互式* Claude Code TUI：
启动 Claude、输入你的 prompt、自动回答权限提示，再抓取最终回复。
你获得了 headless 的使用体验；而 Claude 以为自己是一个普通的交互式会话。

```text
claude -p     →  headless 模式    →  Agent SDK 额度池
ccp.sh "..."  →  交互式 TUI       →  订阅额度池 ✅
```

## 环境要求

- [`claude`](https://code.claude.com/docs#get-started)（已登录）
- [`tmux`](https://github.com/tmux/tmux)
- [`jq`](https://jqlang.github.io/jq/)

## 安装

### Homebrew

```bash
brew install mthli/tap/ccp
```

它会自动拉取 `tmux` 和 `jq`，并在你的 `PATH` 上放置一个 `ccp` 命令（下面示例中凡是写 `./ccp.sh` 的地方都可以用 `ccp`）。
你仍需单独安装 [`claude`](https://code.claude.com/docs#get-started) 并登录。

### 从源码安装

```bash
git clone https://github.com/mthli/ccp.git
cd ccp
./ccp.sh "say hi"
```

## 用法

```bash
./ccp.sh "<prompt>"
```

prompt 输入进去，最终答案从 stdout 输出：

```bash
./ccp.sh "summarize README.md"
./ccp.sh "say hi" # 快速的端到端冒烟测试。
```

### 权限模式

默认情况下，每次工具调用都会被自动批准（`allow`）。
用 `-p` 选择工具调用的处理方式：

```bash
./ccp.sh -p allow "refactor utils.py" # 自动批准一切（默认）。
./ccp.sh -p deny  "scan the repo"     # 拒绝每一次工具调用。
./ccp.sh -p ask   "edit config"       # 交还给 TUI 的常规提示。
```

> 即使在 `allow` 模式下，少数不可逆的 Bash 命令（`rm -rf`、`mkfs`、`dd if=`、fork 炸弹……）也始终会被硬性拒绝。

### 设置环境变量

`-e KEY=VALUE`（可重复）在启动的会话上设置环境变量，由 Claude 及它运行的每个 hook 继承：

```bash
./ccp.sh -e FOO=bar -e DEBUG=1 "print the FOO env var"
```

### 命名 tmux 会话

默认情况下，每次运行都会使用一个唯一的 `cc-<pid>` tmux 会话。传入 `-s` 可以自己指定会话名，便于 attach（`tmux attach -t <name>`）或并行运行多个会话：

```bash
./ccp.sh -s review "review the diff"
```

> 会话名不能包含 `.` 或 `:`，也不能与已存在的会话同名（ccp 绝不会复用或终止不是它自己创建的会话）。

### 向 claude 传递选项

`--` 之后的一切都会原样转发给底层的 `claude`，因此它自己的 flag 都能直接生效：

```bash
./ccp.sh "review the diff" -- --model opus --add-dir /tmp
./ccp.sh "audit deps"      -- --settings ./my-settings.json --mcp-config ./mcp.json
```

> `--settings` 会被深度合并进 ccp 自己的 settings；claude 的 `-p`/`--print` 会被忽略，因为 ccp 正是用来替代 headless 模式的。

### 环境变量覆盖项

| 变量                 | 默认值  | 含义                                          |
| -------------------- | ------- | --------------------------------------------- |
| `CCP_READY_TIMEOUT`  | `60`    | 等待输入框出现的秒数。                         |
| `CCP_ANSWER_TIMEOUT` | `0`     | 等待答案的秒数；`0` = 永远等待。              |

运行 `./ccp.sh --help` 查看完整的选项列表。

## 工作原理

`ccp` 是纯 bash，没有构建步骤，除上述三个工具外没有任何依赖。

它协调四个文件：

- **`ccp.sh`** —— 编排器。
  写出一个一次性的 settings 文件（你真正的 `~/.claude/settings.json` 永不被触碰），
  在分离的 tmux 会话中启动 `claude`，粘贴 prompt，等待完成，并打印答案。
- **`hooks/auto-permission.sh`** —— 一个 `PreToolUse` hook，负责回答每个权限提示，
  使 TUI 永不卡在 y/n 询问框上。
- **`hooks/dump-transcript.sh`** —— 一个 `Stop` hook，从 transcript 中拉取最终的 assistant 回复，
  并通知编排器任务已完成。
- **`hooks/dump-failure.sh`** —— 一个 `StopFailure` hook，当 API 错误结束本回合时触发，
  让 ccp 停止等待并退出，而不是挂起。

如果你的用量耗尽，ccp 不会挂起：API 错误的回合会触发 `StopFailure` hook（退出码 `5`），
而订阅用量上限墙——TUI 会显示它但不结束回合，因此不触发任何 hook——会通过扫描 pane 检测到并以退出码 `4` 退出。
每次退出时，tmux 会话和临时文件都会被清理。

## 许可证

```text
MIT License

Copyright (c) 2026 Matthew Lee
```
