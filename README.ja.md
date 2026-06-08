# ccp

[English](README.md) · [简体中文](README.zh-CN.md) · [繁體中文](README.zh-TW.md) · [한국어](README.ko.md)

ヘッドレスモードを使わない Claude Code のヘッドレス自動化 👀

## これは何か

`ccp` は `claude -p` のように Claude Code を実行し（プロンプトを与え、最終的な回答を stdout で受け取る）、ただし**課金は Agent SDK のクレジットプールではなく、あなたのサブスクリプションに対して行われます**。

その仕組みは、分離された [tmux](https://github.com/tmux/tmux) セッションの中で本物の*インタラクティブ*な Claude Code TUI を駆動することです。
Claude を起動し、プロンプトを入力し、権限プロンプトに自動応答し、最終的な返答をスクレイピングします。
あなたはヘッドレスの使い勝手を得られますが、Claude 側は自分が普通のインタラクティブセッションだと思っています。

```text
claude -p     →  ヘッドレスモード     →  Agent SDK クレジットプール
ccp.sh "..."  →  インタラクティブ TUI →  サブスクリプションプール ✅
```

## 必要なもの

- [`claude`](https://code.claude.com/docs#get-started)（ログイン済み）
- [`tmux`](https://github.com/tmux/tmux)
- [`jq`](https://jqlang.github.io/jq/)

## インストール

### Homebrew

```bash
brew install mthli/tap/ccp
```

これにより `tmux` と `jq` が自動的に取り込まれ、`PATH` 上に `ccp` コマンドが配置されます（以下の例で `./ccp.sh` と書かれている箇所はすべて `ccp` で代用できます）。
[`claude`](https://code.claude.com/docs#get-started) は別途インストールしてログインしておく必要があります。

### ソースから

```bash
git clone https://github.com/mthli/ccp.git
cd ccp
./ccp.sh "say hi"
```

## 使い方

```bash
./ccp.sh "<prompt>"
```

プロンプトを入力すると、最終的な回答が stdout に出力されます。

```bash
./ccp.sh "summarize README.md"
./ccp.sh "say hi" # 手軽なエンドツーエンドのスモークテスト。
```

### 権限モード

デフォルトでは、すべてのツール呼び出しが自動承認されます（`allow`）。
`-p` でツール呼び出しの扱い方を選べます。

```bash
./ccp.sh -p allow "refactor utils.py" # すべて自動承認（デフォルト）。
./ccp.sh -p deny  "scan the repo"     # すべてのツール呼び出しを拒否。
./ccp.sh -p ask   "edit config"       # TUI の通常のプロンプトに委ねる。
```

> `allow` モードであっても、いくつかの不可逆な Bash コマンド（`rm -rf`、`mkfs`、`dd if=`、フォーク爆弾など）は常に強制的に拒否されます。

### 環境変数の設定

`-e KEY=VALUE`（繰り返し指定可）は起動されたセッションに環境変数を設定し、Claude およびそれが実行するすべての hook に継承されます。

```bash
./ccp.sh -e FOO=bar -e DEBUG=1 "print the FOO env var"
```

### tmux セッションの命名

デフォルトでは、各実行は一意な `cc-<pid>` tmux セッションを使用します。`-s` を渡すと自分でセッション名を付けられます。attach（`tmux attach -t <name>`）したり、複数を並行して実行したりするのに便利です。

```bash
./ccp.sh -s review "review the diff"
```

> セッション名に `.` や `:` を含めることはできず、既存のセッションと同名にすることもできません（ccp は自分が作成していないセッションを再利用したり終了させたりすることは決してありません）。

### claude へのオプションの受け渡し

`--` 以降はすべてそのまま下層の `claude` に転送されるため、claude 自身のフラグがそのまま機能します。

```bash
./ccp.sh "review the diff" -- --model opus --add-dir /tmp
./ccp.sh "audit deps"      -- --settings ./my-settings.json --mcp-config ./mcp.json
```

> `--settings` は ccp 自身の settings にディープマージされます。claude の `-p`/`--print` は、ccp がまさにヘッドレスモードを置き換えるものなので無視されます。

### 環境変数によるオーバーライド

| 変数                 | デフォルト | 意味                                              |
| -------------------- | ---------- | ------------------------------------------------- |
| `CCP_READY_TIMEOUT`  | `60`       | 入力ボックスが表示されるまで待つ秒数。            |
| `CCP_SUBMIT_TIMEOUT` | `10`       | プロンプトを送信するまで Enter を再送する秒数。   |
| `CCP_ANSWER_TIMEOUT` | `0`        | 回答を待つ秒数。`0` = 無限に待つ。               |

すべてのオプションの一覧は `./ccp.sh --help` で確認できます。

## 仕組み

`ccp` は純粋な bash で、ビルドステップはなく、上記の 3 つのツール以外に依存関係はありません。

4 つのファイルが連携します。

- **`ccp.sh`** - オーケストレーター。
  使い捨ての settings ファイルを書き出し（あなたの本物の `~/.claude/settings.json` は一切触られません）、
  分離された tmux セッションで `claude` を起動し、プロンプトを貼り付け、完了を待ち、回答を出力します。
- **`hooks/auto-permission.sh`** - 各権限プロンプトに応答する `PreToolUse` hook。
  これにより TUI が y/n の確認ボックスでブロックされることがなくなります。
- **`hooks/dump-transcript.sh`** - transcript から最終的な assistant の返答を取り出し、
  完了したことをオーケストレーターに知らせる `Stop` hook。
- **`hooks/dump-failure.sh`** - API エラーでターンが終了したときに発火する `StopFailure` hook。
  ccp が待機をやめて、ハングせずに終了できるようにします。

使用量を使い切っても ccp はハングしません。API エラーのターンは `StopFailure` hook を発火させ（終了コード `5`）、
サブスクリプションの使用量上限の壁（TUI はそれを表示しますがターンを終了させず、どの hook も発火しません）は
pane をスキャンして検出し、終了コード `4` で終了します。tmux セッションと一時ファイルは、終了のたびにクリーンアップされます。

## ライセンス

```text
MIT License

Copyright (c) 2026 Matthew Lee
```
