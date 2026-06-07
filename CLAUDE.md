# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`ccp` drives an **interactive** Claude Code TUI inside a detached tmux session as if it were `claude -p`. The point is billing: `claude -p` (true headless mode) bills the Agent SDK credit pool, whereas an interactive session bills the subscription pool. So `ccp.sh` automates the interactive TUI — feeding a prompt, auto-answering permission prompts, and scraping the final answer — to get headless ergonomics on the subscription pool. The README tagline is "Headless Claude Code automation without the headless mode."

Pure bash. No build, no package manager, no test suite. Dependencies: `tmux`, `jq`, and the `claude` CLI.

## Commands

```bash
./ccp.sh [-p allow|deny|ask] [-s NAME] [-e KEY=VALUE]... "<prompt>" [-- <claude-options>...]  # run headlessly
./ccp.sh --help                                            # usage
./ccp.sh "say hi"                                          # end-to-end smoke test (see below)
./ccp.sh "review" -- --model opus --add-dir /tmp           # forward claude's own options
shfmt -w ccp.sh hooks/*.sh                                 # format (.editorconfig: 2-space indent, LF)
```

There is no test suite. Verify a change by running the script end-to-end (e.g. `./ccp.sh "say hi"`) — that is the only real test: it exercises the whole launch → readiness → prompt-feed → hook → extract pipeline, and bills a live subscription session (so you must be logged into `claude`).

Before `--`: the prompt is the sole positional arg; everything else is a ccp flag (so a bare `deny` is unambiguously the prompt), and an unrecognized `-flag` is an error. Permission mode (`-p`/`--permission`, default `allow`): `allow` auto-approves every tool call (dangerous Bash is still hard-denied), `deny` rejects everything, `ask` defers to the TUI's normal prompt. `-e`/`--env KEY=VALUE` (repeatable) sets an env var on the launched session via `tmux new-session -e`. `-s`/`--session NAME` names the tmux session (default `cc-<pid>`); it may not contain `.`/`:` and may not collide with an existing session — ccp only ever kills a session it created, never one it didn't.

After `--`: everything is forwarded **verbatim** to the underlying `claude`, so its own options (`--model`, `--add-dir`, `--mcp-config`, …) just work — no per-flag knowledge in ccp, so new claude flags need no ccp change. `--` was chosen over an inline arity table precisely because claude's variadic options (`--add-dir a b c`, `--tools`, `--mcp-config`, …) make inline prompt/value disambiguation impossible. Two passthrough flags are intercepted instead of forwarded: **`--settings <file|json>`** (repeatable) is deep-merged into ccp's generated settings — later values win, and ccp's own `PreToolUse`/`Stop`/`StopFailure` hooks always override the user's for those three events while every other setting (model, env, `PostToolUse`, …) is kept; **`-p`/`--print`** is dropped with a warning, since claude's headless mode is the very thing ccp replaces (use ccp's own `-p`/`--permission`).

Env overrides: `CCP_READY_TIMEOUT` (default 60s, wait for input box) and `CCP_ANSWER_TIMEOUT` (default 0 = wait forever, since prompt complexity is unbounded).

Exit codes: `0` success; `1` runtime failure (session died / answer timeout / bad `--settings`); `2` usage/CLI error (bad args); `4` usage limit reached (quota/credit/429 wall — claude is blocking until reset); `5` turn failed via `StopFailure` (an API error ended the turn); `127` missing dependency or hook; `130`/`143` interrupted (SIGINT/SIGTERM). Codes `4` and `5` exist so a caller looping ccp can tell "back off until reset" apart from a transient API error worth retrying.

## Architecture

Four files cooperate. `ccp.sh` is the orchestrator; the three hooks run *inside* the spawned Claude process and communicate back via files.

**`ccp.sh`** — the orchestrator, in numbered steps:
1. Writes a throwaway `--settings` JSON into a `mktemp -d` rundir, wiring three hooks (`PreToolUse` → `auto-permission.sh`, `Stop` → `dump-transcript.sh`, `StopFailure` → `dump-failure.sh`). The user's real `~/.claude/settings.json` is never touched. Hook paths/args are baked straight into the command strings — nothing is smuggled through tmux env. Any passthrough `--settings` is deep-merged underneath this (via `jq`), with ccp's three hooks overlaid last so they win.
2. Launches `claude --settings ...` (plus any passthrough args after `--`, each `shq`-quoted so spaces/specials survive the shell tmux runs the command through) in a detached tmux session, injecting any `-e KEY=VALUE` via `tmux new-session -e`. claude launches with **no** positional prompt — interactive — so the prompt is only ever pasted in step 4, never passed as a CLI arg.
3. Polls `tmux capture-pane` until the input box is ready, dismissing the "trust this folder" dialog once if it appears.
4. Sends the prompt via `load-buffer`/`paste-buffer` (newline-safe, so multi-line prompts don't submit early), then `Enter` separately.
5. Blocks until one of three things happens: the `Stop` hook drops the `done` sentinel (success → step 6), the `StopFailure` hook drops the `fail` sentinel (API error → exit 5), or the pane shows a usage-limit wall (quota block → exit 4). The last is pane-scraped because the subscription session/weekly/Opus walls fire *no* hook (the TUI just blocks until reset), so without it the wait would hang forever.
6. `cat`s the captured answer to stdout.

A single `cleanup` trap (EXIT/INT/TERM) removes the rundir and kills the tmux session — but only one ccp actually started (a `SESSION_STARTED` guard), so dying on a `-s` name collision never tears down a pre-existing session.

**`hooks/auto-permission.sh`** (PreToolUse) — emits a permission decision so the TUI never shows a y/n box, removing any need to scrape the pane for prompts. Even under `allow` it hard-denies irreversible Bash footguns (`rm -rf`, `mkfs`, `dd if=`, fork bombs, writes to `/dev/sd*`).

**`hooks/dump-transcript.sh`** (Stop) — first checks the Stop payload's `background_tasks` array for an in-flight task whose `type` is `workflow` or `subagent` (the types that later wake a fresh turn with the real answer): if one is present, this Stop is only a *pause*, so the hook exits **without** touching the done-file — the orchestrator waits for the later Stop that fires once the task completes and the agent finishes processing it. Other background types (a `run_in_background` `shell`, a `monitor` watch) are deliberately *not* awaited — they are typically fire-and-forget or long-running and would hang the run. Otherwise it reads the transcript JSONL and extracts "the final answer" = every `assistant` text block after the *last* `user` line (last tool_result, or the prompt). This survives multi-block answers and answers that resume after a tool call; sidechain/subagent lines are excluded. Writes the text to the out-file, then touches the done-file **last** so the orchestrator never reads a half-written answer.

**`hooks/dump-failure.sh`** (StopFailure) — fires *instead of* `Stop` when the turn ends on an API error. Records the `error_type` (`rate_limit`, `billing_error`, `overloaded`, `server_error`, …) to a msg-file, then touches the fail-file **last** (same ordering discipline as dump-transcript). Without it, an API-error turn would never drop the `done` sentinel and the orchestrator would block until the answer-timeout. claude ignores this hook's output/exit code, so the sentinel files are its only effect.

### Things that will bite you if you don't know them

- **Not every `Stop` is the final answer — a backgrounded task parks the turn.** When the agent launches a Workflow or a background subagent the tool returns immediately, the turn ends, and `Stop` fires while the work is still running; the completing task later wakes a fresh turn with the real answer. `dump-transcript.sh` keys off the Stop payload's `background_tasks` array (verified in the claude binary's hook-input schema), each entry tagged with a `type`, and withholds the done sentinel only while a `workflow` or `subagent` task is in flight. Other types are deliberately NOT awaited: a `run_in_background` `shell` or a `monitor` watch is typically fire-and-forget or long-running, so blocking on it would hang the run forever while the agent already considers its turn done — the same reason the sibling `session_crons` array (future scheduled work) is ignored. Older claude builds omit `background_tasks`; it reads as empty and the run behaves exactly as before.
- **Re-entrant `Stop` hooks bill the Agent SDK pool — suppress them with `-e`.** A global `Stop` hook that re-enters `claude -p` (spawns a nested Claude session per turn) fires during headless runs and bills the Agent SDK credit pool — the exact thing ccp exists to avoid. `-e KEY=VALUE` sets *any* env var on the launched session (inherited by claude and every hook/subprocess it runs), so set whatever guard var disables such a hook. It injects via `tmux new-session -e`, writing straight into the session env, so it lands regardless of tmux server state — unlike ambient inheritance, which a pre-existing tmux server silently drops (it hands new sessions its own stale env).
- **Readiness detection is signal-based, not "shortcuts"-based.** `ccp.sh` greps for `(shift+tab to cycle)` / `? for shortcuts` / an empty `❯` prompt line, because a custom statusline can hide the shortcuts hint. If the TUI wording changes, this is what breaks — the env timeouts exist as the escape hatch.
- **`Stop` fires before the final JSONL line flushes.** `dump-transcript.sh` re-reads up to ~6s (30 × 0.2s) until the final text block lands; reading once races to an empty result.
- **PreToolUse output schema is `hookSpecificOutput.permissionDecision`** — the legacy `decision: approve/block` is dead for PreToolUse. A hook `allow` cannot override a settings `permissions.deny` rule.
- **Usage-limit walls fire NO hook — only a pane scrape catches them.** The subscription `You've hit your session/weekly/Opus limit` walls make the TUI block until reset *without ending the turn*, so neither `Stop` nor `StopFailure` fires. `ccp.sh` greps the pane for the [documented wordings](https://code.claude.com/docs/en/errors#usage-limits) and exits `4`; the patterns are kept specific (the exact phrases, not a loose `.*limit`) because they run against the *streaming* pane and a loose match would trip on an answer that merely discusses rate limits. API-path errors (429/billing/overloaded) do fire `StopFailure` (→ exit 5), but the same phrases are also in the pane matcher as a backstop for claude builds without the `StopFailure` event.

## Branching

Default working branch is `develop`; PRs target `master`.
