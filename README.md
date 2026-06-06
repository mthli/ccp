# ccp

[简体中文](README.zh-CN.md) · [繁體中文](README.zh-TW.md) · [日本語](README.ja.md) · [한국어](README.ko.md)

Headless Claude Code automation without the headless mode 👀

## What it is

`ccp` runs Claude Code like `claude -p` (feed a prompt, get the final answer on stdout), but **bills your subscription instead of the Agent SDK credit pool**.

It does this by driving a real *interactive* Claude Code TUI inside a detached [tmux](https://github.com/tmux/tmux) session:
it launches Claude, types in your prompt, auto-answers the permission prompts, and scrapes the final reply.
You get headless ergonomics; Claude thinks it's a normal interactive session.

```text
claude -p     →  headless mode    →  Agent SDK credit pool
ccp.sh "..."  →  interactive TUI  →  subscription pool ✅
```

## Requirements

- [`claude`](https://code.claude.com/docs#get-started) (logged in)
- [`tmux`](https://github.com/tmux/tmux)
- [`jq`](https://jqlang.github.io/jq/)

## Installation

### Homebrew

```bash
brew install mthli/tap/ccp
```

This pulls in `tmux` and `jq` automatically and puts a `ccp` command on your `PATH` (use `ccp` wherever the examples below say `./ccp.sh`).
You still need [`claude`](https://code.claude.com/docs#get-started) installed separately and logged in.

### From source

```bash
git clone https://github.com/mthli/ccp.git
cd ccp
./ccp.sh "say hi"
```

## Usage

```bash
./ccp.sh "<prompt>"
```

The prompt goes in, the final answer comes out on stdout:

```bash
./ccp.sh "summarize README.md"
./ccp.sh "say hi" # quick end-to-end smoke test.
```

### Permission mode

By default every tool call is auto-approved (`allow`).
Choose how tool calls are handled with `-p`:

```bash
./ccp.sh -p allow "refactor utils.py" # auto-approve everything (default).
./ccp.sh -p deny  "scan the repo"     # reject every tool call.
./ccp.sh -p ask   "edit config"       # defer to the TUI's normal prompt.
```

> Even under `allow`, a few irreversible Bash commands (`rm -rf`, `mkfs`, `dd if=`, fork bombs, …) are always hard-denied.

### Setting environment variables

`-e KEY=VALUE` (repeatable) sets env vars on the launched session, inherited by Claude and every hook it runs:

```bash
./ccp.sh -e FOO=bar -e DEBUG=1 "print the FOO env var"
```

### Naming the tmux session

By default the run uses a unique `cc-<pid>` tmux session. Pass `-s` to name it yourself, handy for attaching (`tmux attach -t <name>`) or running side by side:

```bash
./ccp.sh -s review "review the diff"
```

> The name must not contain `.` or `:`, and must not match an existing session (ccp never reuses or kills a session it didn't create).

### Passing options to claude

Everything after `--` is forwarded verbatim to the underlying `claude`, so its own flags just work:

```bash
./ccp.sh "review the diff" -- --model opus --add-dir /tmp
./ccp.sh "audit deps"      -- --settings ./my-settings.json --mcp-config ./mcp.json
```

> `--settings` is deep-merged into ccp's own settings; claude's `-p`/`--print` is ignored since ccp replaces headless mode.

### Environment overrides

| Variable             | Default | Meaning                                             |
| -------------------- | ------- | --------------------------------------------------- |
| `CCP_READY_TIMEOUT`  | `60`    | Seconds to wait for the input box to appear.        |
| `CCP_ANSWER_TIMEOUT` | `0`     | Seconds to wait for the answer; `0` = wait forever. |

Run `./ccp.sh --help` for the full list of options.

## How it works

`ccp` is pure bash, with no build step and no dependencies beyond the three tools above.

It coordinates three files:

- **`ccp.sh`** - the orchestrator.
  Writes a throwaway settings file (your real `~/.claude/settings.json` is never touched),
  launches `claude` in a detached tmux session, pastes the prompt, waits for completion, and prints the answer.
- **`hooks/auto-permission.sh`** - a `PreToolUse` hook that answers each permission prompt,
  so the TUI never blocks on a y/n box.
- **`hooks/dump-transcript.sh`** - a `Stop` hook that pulls the final assistant reply out of the transcript
  and signals the orchestrator that it's done.

The tmux session and temp files are cleaned up on every exit.

## License

```text
MIT License

Copyright (c) 2026 Matthew Lee
```
