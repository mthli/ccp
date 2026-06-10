#!/usr/bin/env bash
# Stop hook: extract this turn's final assistant text from the transcript JSONL
# and signal the outer orchestrator via sentinel files.
#
# Usage (baked into --settings command line):
#   dump-transcript.sh <out_file> <done_file> [ccp_pid] [session]
#
# The optional pair drives the orphan self-destruct at the bottom: ccp's trap is
# the only other thing that ever kills the session, so if ccp died untrappably
# (SIGKILL) the hook reaps its own session once the final answer is recorded.
#
# Transcript schema (verified against real ~/.claude/projects/**/*.jsonl):
#   - one JSONL line per content block
#   - .type == "assistant", .message.content[] has .type in {text, thinking, tool_use}
#   - tool results come back as .type == "user" lines
# So "the final answer" = every assistant text block AFTER the last `user`
# entry (last tool_result, or the prompt itself if no tools ran). This beats a
# naive `last text` because it keeps multi-block final answers and survives an
# answer that resumes after a tool call. Sidechain (subagent) lines excluded.
#
# Not every Stop is final. When the turn only paused because a backgrounded task
# is still in flight, this Stop fires now, but that task later wakes a fresh turn
# that produces the real answer. Claude Code reports in-flight work in the Stop
# payload's `background_tasks` array; each entry has a `type` (a friendly label)
# and a `status` ('pending'|'running'|'completed'|'failed'|'killed'|'paused'). The
# binary maps its internal task kinds to these friendly labels (verified against
# the hook-input schema + the label map in the 2.1.x binary):
#   local_agent -> subagent
#   local_workflow -> workflow
#   local_bash -> shell
#   in_process_teammate -> teammate
#   remote_agent -> "cloud session"
#   monitor_mcp -> monitor
#   mcp_task -> "MCP task"
#   dream -> dream
#
# We hold the run open (exit WITHOUT dropping the done sentinel, so the orchestrator
# keeps waiting) for the WAKE-CAPABLE types — the finite ones that re-enter the
# agent with the real answer: `subagent`, `workflow`, `shell`, `teammate`, and
# `cloud session` — but only while their `status` is running/pending. The final
# Stop (none of those left) is the one that writes OUT and touches DONE.
#
# `shell` is the subtle one (and was NOT awaited before — that dropped the answer):
# a backgrounded Bash (`run_in_background: true`, e.g. a long-running command)
# re-enters the agent via a task-notification when it EXITS, but only in an
# interactive session — claude's own Bash docs note a headless `-p` run is never
# resumed. ccp drives the interactive TUI, so the wake fires; tearing the session
# down at the first Stop killed it before it could wake the consuming turn. The
# `status` gate keeps
# awaiting-shells safe: a `paused` shell, and (on builds that leave finished tasks
# in the array) a `completed`/`failed`/`killed` one, are not awaited, so a finite
# command the agent ignored never holds the run open. Caveat — a turn-boundary
# race remains: if a task finishes in the same instant the turn ends with its wake
# still queued, the gate can drop done one Stop early; this is inherent (it applies
# to workflow/subagent too) and not introduced by the status gate.
#
# NOT awaited, on purpose: `monitor` (an MCP watch) and `MCP task` (a generic async
# MCP task) — both can fire on a condition or run open-endedly, so awaiting them
# risks hanging the run forever; `dream` (background reflection, never the user's
# answer); the sibling `session_crons` array (future scheduled work); and a
# backgrounded process that never exits (a dev server stays `running`, so the run
# waits on it until CCP_ANSWER_TIMEOUT — the deliberate cost of awaiting shells).
# Older claude builds omit `background_tasks` (reads as empty) or a task's `status`
# (treated as running, i.e. awaited) — both keep the prior behaviour.
set -euo pipefail

OUT="${1:?usage: dump-transcript.sh <out_file> <done_file>}"
DONE="${2:?usage: dump-transcript.sh <out_file> <done_file>}"

INPUT="$(cat || true)"

# Background-work gate (see the header for the full type/status model): withhold
# done while a wake-capable task — `subagent`, `workflow`, `shell`, `teammate`, or
# `cloud session` — is still `running`/`pending`, so the orchestrator waits for the
# turn that task wakes instead of ending on this pause. `monitor`/`MCP task`/`dream`
# are excluded (a watch / open-ended async task / reflection never delivers this
# turn's one answer). `// []` keeps older builds (no field) on the normal path;
# `.status // "running"` treats a status-less entry as awaited (prior behaviour);
# `index` is truthy for a match (including index 0). The guards keep us on the
# normal path on any jq hiccup rather than swallowing the answer.
GATE='[(.background_tasks // [])[]
  | (.status // "running") as $s
  | .type as $t
  | select(($s == "running" or $s == "pending")
           and (["subagent", "workflow", "shell", "teammate", "cloud session"] | index($t)))
] | length'
if [ "$(jq -r "$GATE" <<<"$INPUT" 2>/dev/null || echo 0)" -gt 0 ] 2>/dev/null; then
  exit 0
fi

TRANSCRIPT="$(jq -r '.transcript_path // ""' <<<"$INPUT" 2>/dev/null || echo "")"

extract() {
  jq -s -r '
    ([ .[] | .type ] | map(. == "user") | rindex(true)) as $u
    | (if $u == null then 0 else $u + 1 end) as $start
    | [ .[$start:][]
        | select(.type == "assistant" and (.isSidechain != true))
        | .message.content[]?
        | select(.type == "text")
        | .text ]
    | join("\n\n")
  ' "$1" 2>/dev/null || true
}

# Stop fires the instant the answer message is created, but each content block is
# its own JSONL line and they flush a few hundred ms apart — reading immediately
# races to an empty (or partial) result. Re-read until the extract is non-empty
# AND unchanged across one poll, so a multi-block final answer isn't captured
# mid-flush and returned truncated. Bounded ~6s.
LAST=""
if [[ -n "$TRANSCRIPT" && -f "$TRANSCRIPT" ]]; then
  PREV=""
  for _ in $(seq 1 30); do
    LAST="$(extract "$TRANSCRIPT")"
    [[ -n "$LAST" && "$LAST" == "$PREV" ]] && break
    PREV="$LAST"
    sleep 0.2
  done
fi

printf '%s\n' "$LAST" >"$OUT"
: >"$DONE" # touch completion sentinel LAST, so OUT is ready when DONE appears

# Orphan self-destruct (best-effort): ccp's EXIT/INT/TERM trap is the only other
# thing that ever runs `tmux kill-session`, and an untrappable SIGKILL skips it —
# seen in production when a supervisor (pm2) SIGINTs the wrapper shell, which
# neither dies nor forwards while waiting on ccp, then escalates to a tree-wide
# SIGKILL. The interactive TUI never exits on its own, so the orphaned session
# would sit at the input box forever and every later run reusing the -s name
# would die on ccp's collision check. The sentinel is already down (the answer is
# complete and recorded), so if the launching ccp is gone there is nobody left to
# read it or to tear the session down — kill our own session. kill -0 probes
# liveness; ccp runs as this same user, so EPERM (the PID reused by another
# user's process) also means our ccp is dead. If ccp is alive, teardown stays its
# job, as before. Args absent or malformed (manual use, older ccp.sh) → no-op.
CCP_PID="${3:-}"
CCP_SESSION="${4:-}"
case "$CCP_PID" in '' | *[!0-9]*) exit 0 ;; esac
[ -n "$CCP_SESSION" ] || exit 0
if kill -0 "$CCP_PID" 2>/dev/null; then
  exit 0 # ccp alive — it reads OUT and kills the session via its trap
fi
# Reap the rundir too — ccp's trap is the only other thing that removes it, and
# the sentinel files just written have no reader left. Guarded on the cc-run.*
# shape ccp's mktemp uses, so a hand-supplied path never gets a recursive rm.
RUNDIR="$(dirname "$DONE")"
case "$RUNDIR" in
*/cc-run.*) rm -rf "$RUNDIR" ;;
esac
# Last, since this kills claude (and this hook with it). '=' pins the target to
# an exact name match — never tmux's prefix fallback.
tmux kill-session -t "=$CCP_SESSION" 2>/dev/null || true
