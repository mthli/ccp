#!/usr/bin/env bash
# Stop hook: extract this turn's final assistant text from the transcript JSONL
# and signal the outer orchestrator via sentinel files.
#
# Usage (baked into --settings command line):
#   dump-transcript.sh <out_file> <done_file>
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
# Not every Stop is final. When the turn only paused because a backgrounded
# Workflow or subagent is still in flight, this Stop fires now, but that task
# later wakes a fresh turn that produces the real answer. Claude Code reports
# in-flight work in the Stop payload's `background_tasks` array, each entry tagged
# with a `type` ('workflow', 'subagent', 'shell', 'monitor', ...). We hold the run
# open only for the types that re-enter the agent with a real answer — `workflow`
# and `subagent` — exiting WITHOUT dropping the done sentinel so the orchestrator
# keeps waiting; the final Stop (none of those left) is the one that writes OUT
# and touches DONE. Other types are NOT awaited on purpose: a `run_in_background`
# `shell` or a `monitor` watch is typically fire-and-forget or long-running, so
# blocking on it would hang the run while the agent already considers its turn
# done. The separate `session_crons` array is ignored for the same reason — a
# scheduled cron is future work, not this turn's pending answer. Older claude
# builds omit `background_tasks`; it reads as empty, so behaviour is unchanged.
set -euo pipefail

OUT="${1:?usage: dump-transcript.sh <out_file> <done_file>}"
DONE="${2:?usage: dump-transcript.sh <out_file> <done_file>}"

INPUT="$(cat || true)"

# Background-work gate (see header): if a `workflow`/`subagent` background task is
# still in flight, this Stop is a pause, not the final answer — exit without
# signalling done so the orchestrator waits for the turn the completing task
# wakes. Other types (`shell`, `monitor`, ...) are not counted, so a fire-and-
# forget background process never holds the run open. `// []` keeps older builds
# (no field) on the normal path; the guards leave us on the normal path on any
# jq/parse hiccup rather than swallowing the answer.
if [ "$(jq -r '[(.background_tasks // [])[] | select(.type == "workflow" or .type == "subagent")] | length' <<<"$INPUT" 2>/dev/null || echo 0)" -gt 0 ] 2>/dev/null; then
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
