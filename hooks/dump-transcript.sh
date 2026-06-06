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
set -euo pipefail

OUT="${1:?usage: dump-transcript.sh <out_file> <done_file>}"
DONE="${2:?usage: dump-transcript.sh <out_file> <done_file>}"

INPUT="$(cat || true)"
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

# Stop fires the instant the answer message is created, but the JSONL line for
# that final text can flush a few hundred ms later — reading immediately races
# to an empty result. Re-read until the final block lands (bounded ~6s).
LAST=""
if [[ -n "$TRANSCRIPT" && -f "$TRANSCRIPT" ]]; then
	for _ in $(seq 1 30); do
		LAST="$(extract "$TRANSCRIPT")"
		[[ -n "$LAST" ]] && break
		sleep 0.2
	done
fi

printf '%s\n' "$LAST" >"$OUT"
: >"$DONE" # touch completion sentinel LAST, so OUT is ready when DONE appears
