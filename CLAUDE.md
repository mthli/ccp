# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`ccp` drives an **interactive** Claude Code TUI inside a detached tmux session as if it were `claude -p`. The point is billing: `claude -p` (true headless mode) bills the Agent SDK credit pool, whereas an interactive session bills the subscription pool. So `ccp.sh` automates the interactive TUI — feeding a prompt, auto-answering permission prompts, and scraping the final answer — to get headless ergonomics on the subscription pool. The README tagline is "Headless Claude Code automation without the headless mode."

Pure bash. No build, no package manager, no test suite. Dependencies: `tmux`, `jq`, and the `claude` CLI.

## Commands

```bash
./ccp.sh [-p allow|deny|ask] [-e KEY=VALUE]... "<prompt>"  # run headlessly; answer prints to stdout
./ccp.sh --help                                            # usage
shfmt -w ccp.sh hooks/*.sh                                 # format (.editorconfig: 2-space indent, LF)
```

The prompt is the sole positional arg; everything else is a flag (so a bare `deny` is unambiguously the prompt). Permission mode (`-p`/`--permission`, default `allow`): `allow` auto-approves every tool call (dangerous Bash is still hard-denied), `deny` rejects everything, `ask` defers to the TUI's normal prompt. `-e`/`--env KEY=VALUE` (repeatable) sets an env var on the launched session via `tmux new-session -e`.

Env overrides: `CCP_READY_TIMEOUT` (default 60s, wait for input box) and `CCP_ANSWER_TIMEOUT` (default 0 = wait forever, since prompt complexity is unbounded).

## Architecture

Three files cooperate. `ccp.sh` is the orchestrator; the two hooks run *inside* the spawned Claude process and communicate back via files.

**`ccp.sh`** — the orchestrator, in numbered steps:
1. Writes a throwaway `--settings` JSON into a `mktemp -d` rundir, wiring two hooks (`PreToolUse` → `auto-perm.sh`, `Stop` → `dump-transcript.sh`). The user's real `~/.claude/settings.json` is never touched. Hook paths/args are baked straight into the command strings — nothing is smuggled through tmux env.
2. Launches `claude --settings ...` in a detached tmux session, injecting any `-e KEY=VALUE` via `tmux new-session -e`.
3. Polls `tmux capture-pane` until the input box is ready, dismissing the "trust this folder" dialog once if it appears.
4. Sends the prompt via `load-buffer`/`paste-buffer` (newline-safe, so multi-line prompts don't submit early), then `Enter` separately.
5. Blocks until the `Stop` hook drops a `done` sentinel file.
6. `cat`s the captured answer to stdout.

A single `cleanup` trap (EXIT/INT/TERM) always kills the tmux session and removes the rundir.

**`hooks/auto-perm.sh`** (PreToolUse) — emits a permission decision so the TUI never shows a y/n box, removing any need to scrape the pane for prompts. Even under `allow` it hard-denies irreversible Bash footguns (`rm -rf`, `mkfs`, `dd if=`, fork bombs, writes to `/dev/sd*`).

**`hooks/dump-transcript.sh`** (Stop) — reads the transcript JSONL and extracts "the final answer" = every `assistant` text block after the *last* `user` line (last tool_result, or the prompt). This survives multi-block answers and answers that resume after a tool call; sidechain/subagent lines are excluded. Writes the text to the out-file, then touches the done-file **last** so the orchestrator never reads a half-written answer.

### Things that will bite you if you don't know them

- **Re-entrant `Stop` hooks bill the Agent SDK pool — suppress them with `-e`.** A global `Stop` hook that re-enters `claude -p` (spawns a nested Claude session per turn) fires during headless runs and bills the Agent SDK credit pool — the exact thing ccp exists to avoid. `-e KEY=VALUE` sets *any* env var on the launched session (inherited by claude and every hook/subprocess it runs), so set whatever guard var disables such a hook. It injects via `tmux new-session -e`, writing straight into the session env, so it lands regardless of tmux server state — unlike ambient inheritance, which a pre-existing tmux server silently drops (it hands new sessions its own stale env).
- **Readiness detection is signal-based, not "shortcuts"-based.** `ccp.sh` greps for `(shift+tab to cycle)` / `? for shortcuts` / an empty `❯` prompt line, because a custom statusline can hide the shortcuts hint. If the TUI wording changes, this is what breaks — the env timeouts exist as the escape hatch.
- **`Stop` fires before the final JSONL line flushes.** `dump-transcript.sh` re-reads up to ~6s (30 × 0.2s) until the final text block lands; reading once races to an empty result.
- **PreToolUse output schema is `hookSpecificOutput.permissionDecision`** — the legacy `decision: approve/block` is dead for PreToolUse. A hook `allow` cannot override a settings `permissions.deny` rule.

## Branching

Default working branch is `develop`; PRs target `master`.
