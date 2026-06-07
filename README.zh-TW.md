# ccp

無需 headless 模式的 Claude Code headless 自動化 👀

## 這是什麼

`ccp` 像 `claude -p` 一樣執行 Claude Code（餵入一個 prompt，從 stdout 取回最終答案），但**計費走你的訂閱額度，而非 Agent SDK 額度池**。

它的做法是在一個分離的 [tmux](https://github.com/tmux/tmux) 工作階段中驅動一個真實的*互動式* Claude Code TUI：
啟動 Claude、輸入你的 prompt、自動回答權限提示，再擷取最終回覆。
你獲得了 headless 的使用體驗；而 Claude 以為自己是一個普通的互動式工作階段。

```text
claude -p     →  headless 模式    →  Agent SDK 額度池
ccp.sh "..."  →  互動式 TUI       →  訂閱額度池 ✅
```

## 環境需求

- [`claude`](https://code.claude.com/docs#get-started)（已登入）
- [`tmux`](https://github.com/tmux/tmux)
- [`jq`](https://jqlang.github.io/jq/)

## 安裝

### Homebrew

```bash
brew install mthli/tap/ccp
```

它會自動拉取 `tmux` 和 `jq`，並在你的 `PATH` 上放置一個 `ccp` 命令（下面範例中凡是寫 `./ccp.sh` 的地方都可以用 `ccp`）。
你仍需單獨安裝 [`claude`](https://code.claude.com/docs#get-started) 並登入。

### 從原始碼安裝

```bash
git clone https://github.com/mthli/ccp.git
cd ccp
./ccp.sh "say hi"
```

## 用法

```bash
./ccp.sh "<prompt>"
```

prompt 輸入進去，最終答案從 stdout 輸出：

```bash
./ccp.sh "summarize README.md"
./ccp.sh "say hi" # 快速的端對端冒煙測試。
```

### 權限模式

預設情況下，每次工具呼叫都會被自動核准（`allow`）。
用 `-p` 選擇工具呼叫的處理方式：

```bash
./ccp.sh -p allow "refactor utils.py" # 自動核准一切（預設）。
./ccp.sh -p deny  "scan the repo"     # 拒絕每一次工具呼叫。
./ccp.sh -p ask   "edit config"       # 交還給 TUI 的常規提示。
```

> 即使在 `allow` 模式下，少數不可逆的 Bash 命令（`rm -rf`、`mkfs`、`dd if=`、fork 炸彈……）也始終會被硬性拒絕。

### 設定環境變數

`-e KEY=VALUE`（可重複）在啟動的工作階段上設定環境變數，由 Claude 及它執行的每個 hook 繼承：

```bash
./ccp.sh -e FOO=bar -e DEBUG=1 "print the FOO env var"
```

### 命名 tmux 工作階段

預設情況下，每次執行都會使用一個唯一的 `cc-<pid>` tmux 工作階段。傳入 `-s` 可以自行指定工作階段名稱，方便 attach（`tmux attach -t <name>`）或同時執行多個工作階段：

```bash
./ccp.sh -s review "review the diff"
```

> 工作階段名稱不能包含 `.` 或 `:`，也不能與既有的工作階段同名（ccp 絕不會重用或終止不是它自己建立的工作階段）。

### 向 claude 傳遞選項

`--` 之後的一切都會原樣轉發給底層的 `claude`，因此它自己的 flag 都能直接生效：

```bash
./ccp.sh "review the diff" -- --model opus --add-dir /tmp
./ccp.sh "audit deps"      -- --settings ./my-settings.json --mcp-config ./mcp.json
```

> `--settings` 會被深度合併進 ccp 自己的 settings；claude 的 `-p`/`--print` 會被忽略，因為 ccp 正是用來取代 headless 模式的。

### 環境變數覆寫項

| 變數                 | 預設值  | 含義                                          |
| -------------------- | ------- | --------------------------------------------- |
| `CCP_READY_TIMEOUT`  | `60`    | 等待輸入框出現的秒數。                         |
| `CCP_ANSWER_TIMEOUT` | `0`     | 等待答案的秒數；`0` = 永遠等待。              |

執行 `./ccp.sh --help` 查看完整的選項列表。

## 運作原理

`ccp` 是純 bash，沒有建置步驟，除上述三個工具外沒有任何相依套件。

它協調四個檔案：

- **`ccp.sh`** —— 協調器。
  寫出一個一次性的 settings 檔案（你真正的 `~/.claude/settings.json` 永不被觸碰），
  在分離的 tmux 工作階段中啟動 `claude`，貼上 prompt，等待完成，並印出答案。
- **`hooks/auto-permission.sh`** —— 一個 `PreToolUse` hook，負責回答每個權限提示，
  使 TUI 永不卡在 y/n 詢問框上。
- **`hooks/dump-transcript.sh`** —— 一個 `Stop` hook，從 transcript 中拉取最終的 assistant 回覆，
  並通知協調器任務已完成。
- **`hooks/dump-failure.sh`** —— 一個 `StopFailure` hook，當 API 錯誤結束本回合時觸發，
  讓 ccp 停止等待並退出，而不是卡住。

如果你的用量耗盡，ccp 不會卡住：API 錯誤的回合會觸發 `StopFailure` hook（退出碼 `5`），
而訂閱用量上限牆——TUI 會顯示它但不結束回合，因此不觸發任何 hook——會透過掃描 pane 偵測到並以退出碼 `4` 退出。
每次退出時，tmux 工作階段和暫存檔案都會被清理。

## 授權條款

```text
MIT License

Copyright (c) 2026 Matthew Lee
```
