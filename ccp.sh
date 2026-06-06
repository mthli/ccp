#!/usr/bin/env bash
# Drive an INTERACTIVE Claude Code TUI inside tmux as if it were `claude -p`,
# so usage bills against the subscription pool, not the Agent SDK credit pool.
#
#   ./ccp.sh "your prompt" [allow|deny|ask]
#
# Outputs the clean final assistant text to stdout. Real ~/.claude/settings.json
# is never touched (temp --settings only); tmux session + temp dir are trapped
# clean on any exit.
set -euo pipefail

PROMPT="${1:?usage: ccp.sh \"prompt\" [allow|deny|ask]}"
AUTO="${2:-allow}"                       # default: auto-approve every tool

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)/hooks"
RUNDIR="$(mktemp -d -t cc-run.XXXXXX)"
SETTINGS="$RUNDIR/settings.json"
OUT="$RUNDIR/output.txt"
DONE="$RUNDIR/done"
SESSION="cc-$$"

# Tunables (override via env if the TUI wording ever changes).
READY_TIMEOUT="${READY_TIMEOUT:-60}"     # seconds to wait for the input box
ANSWER_TIMEOUT="${ANSWER_TIMEOUT:-600}"  # seconds to wait for the answer

cleanup() {
  tmux kill-session -t "$SESSION" 2>/dev/null || true
  rm -rf "$RUNDIR"
}
trap cleanup EXIT INT TERM

# 1) Temp settings: PreToolUse auto-permission + Stop transcript dump.
#    Paths baked straight into the command lines (no env smuggling through tmux).
cat > "$SETTINGS" <<JSON
{
  "hooks": {
    "PreToolUse": [
      { "matcher": "*", "hooks": [
        { "type": "command", "command": "'$HOOK_DIR/auto-perm.sh' $AUTO" }
      ]}
    ],
    "Stop": [
      { "hooks": [
        { "type": "command", "command": "'$HOOK_DIR/dump-transcript.sh' '$OUT' '$DONE'" }
      ]}
    ]
  }
}
JSON

# 2) Launch interactive claude in a detached tmux session.
#    CLAUDE_VOCAB_EXTRACTING=1 trips the statusline-vocab Stop hook's re-entry
#    guard so it does NOT spawn a `claude -p` Haiku call per turn — that nested
#    -p would bill the Agent SDK credit pool, the exact thing this scheme avoids.
#    Drop the prefix if you want vocab to keep updating during headless runs.
tmux new-session -d -s "$SESSION" -x 220 -y 50 \
  "CLAUDE_VOCAB_EXTRACTING=1 claude --settings '$SETTINGS'"

# 3) Wait for the input box. Empirically the reliable signals are the mode hint
#    "(shift+tab to cycle)" / "? for shortcuts" and the empty prompt line; a
#    fresh/untrusted folder first shows a trust dialog we must dismiss. We do NOT
#    grep for "shortcuts" alone — a custom statusline can hide that hint.
pane() { tmux capture-pane -p -t "$SESSION" 2>/dev/null || true; }

ready=0
trust_sent=0
deadline=$(( $(date +%s) + READY_TIMEOUT ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  if ! tmux has-session -t "$SESSION" 2>/dev/null; then
    echo "ERROR: claude session died during startup" >&2
    pane >&2
    exit 1
  fi
  P="$(pane)"

  # Dismiss the "trust this folder" safety prompt once (option 1 is preselected).
  if [ "$trust_sent" -eq 0 ] && grep -qiE 'trust this folder|Yes, I trust' <<<"$P"; then
    tmux send-keys -t "$SESSION" Enter
    trust_sent=1
    sleep 0.3
    continue
  fi

  # Input box ready.
  if grep -qE '\(shift\+tab to cycle\)|\? for shortcuts' <<<"$P" \
     || grep -qE '^[[:space:]]*❯[[:space:]]*$' <<<"$P"; then
    ready=1
    break
  fi
  sleep 0.2
done

if [ "$ready" -ne 1 ]; then
  echo "ERROR: input box not ready within ${READY_TIMEOUT}s" >&2
  pane >&2
  exit 1
fi

# 4) Feed the prompt. load-buffer/paste-buffer is newline-safe (multi-line
#    prompts won't submit early); send Enter separately to submit.
printf '%s' "$PROMPT" | tmux load-buffer -b ccpaste -
tmux paste-buffer -b ccpaste -t "$SESSION" -d
sleep 0.2
tmux send-keys -t "$SESSION" Enter

# 5) Wait for the Stop hook to drop the done sentinel.
adeadline=$(( $(date +%s) + ANSWER_TIMEOUT ))
while [ "$(date +%s)" -lt "$adeadline" ]; do
  [ -f "$DONE" ] && break
  if ! tmux has-session -t "$SESSION" 2>/dev/null; then
    echo "ERROR: claude session died before answering" >&2
    exit 1
  fi
  sleep 0.2
done

# 6) Emit result.
if [ -f "$DONE" ]; then
  cat "$OUT"
else
  echo "ERROR: timed out after ${ANSWER_TIMEOUT}s waiting for the answer" >&2
  exit 1
fi
# 7) cleanup (kill tmux + rm RUNDIR) runs automatically via the trap set above,
#    covering normal exit, every `exit 1` path, and Ctrl-C / kill.
