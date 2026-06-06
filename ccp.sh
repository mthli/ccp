#!/usr/bin/env bash
#
# ccp.sh — run Claude Code headlessly on the subscription pool
# ============================================================
#
# Drives an INTERACTIVE Claude Code TUI inside a detached tmux session as if it
# were `claude -p`, so usage bills against the subscription pool instead of the
# Agent SDK credit pool. The clean final assistant text is printed to stdout.
#
# Usage:
#   ./ccp.sh "<prompt>" [allow|deny|ask]
#
# Arguments:
#   <prompt>              Prompt to send (required; quote multi-line prompts).
#   allow|deny|ask        Tool-permission mode (optional, default: allow):
#                           allow  auto-approve every tool call (irreversible Bash
#                                  footguns are still hard-denied)
#                           deny   auto-reject every tool call
#                           ask    defer to the TUI's normal permission prompt
#
# Environment overrides:
#   CCP_READY_TIMEOUT     Seconds to wait for the input box   (default: 60)
#   CCP_ANSWER_TIMEOUT    Seconds to wait for the answer;
#                         0 = wait forever                    (default: 0)
#
# Safety:
#   Your real ~/.claude/settings.json is never touched (a throwaway --settings
#   file is used); the tmux session and temp dir are cleaned up on any exit.
#
# Example:
#   ./ccp.sh "summarize README.md" allow
#
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ccp.sh "<prompt>" [allow|deny|ask]

  <prompt>          Prompt to send (required; quote multi-line prompts).
  allow|deny|ask    Tool-permission mode (default: allow).

Example:
  ./ccp.sh "summarize README.md" allow
EOF
}

# -h/--help prints usage on stdout and exits cleanly.
case "${1:-}" in
-h | --help)
  usage
  exit 0
  ;;
esac

# Missing prompt or unknown mode: explain on stderr, exit 2 (no bash internals).
if [ "$#" -eq 0 ] || [ -z "${1:-}" ]; then
  {
    echo "ccp.sh: missing required <prompt> argument"
    echo
    usage
  } >&2
  exit 2
fi

PROMPT="$1"
AUTO="${2:-allow}" # tool-permission mode: allow (default) | deny | ask

case "$AUTO" in
allow | deny | ask) ;;
*)
  {
    echo "ccp.sh: invalid permission mode '$AUTO' (expected: allow, deny, or ask)"
    echo
    usage
  } >&2
  exit 2
  ;;
esac

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)/hooks"
RUNDIR="$(mktemp -d -t cc-run.XXXXXX)"
SETTINGS="$RUNDIR/settings.json"
OUT="$RUNDIR/output.txt"
DONE="$RUNDIR/done"
SESSION="cc-$$"

# Tunables (override via env if the TUI wording ever changes).
CCP_READY_TIMEOUT="${CCP_READY_TIMEOUT:-60}" # seconds to wait for the input box
CCP_ANSWER_TIMEOUT="${CCP_ANSWER_TIMEOUT:-0}" # seconds to wait for the answer; 0 = forever

cleanup() {
  tmux kill-session -t "$SESSION" 2>/dev/null || true
  rm -rf "$RUNDIR"
}
# EXIT always cleans up. INT/TERM exit explicitly so Ctrl-C (or `kill`) unwinds
# through the EXIT trap once — removing the temp dir and tmux session — instead
# of running cleanup mid-loop and then continuing to poll.
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# 1) Temp settings: PreToolUse auto-permission + Stop transcript dump.
#    Paths baked straight into the command lines (no env smuggling through tmux).
cat >"$SETTINGS" <<JSON
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
deadline=$(($(date +%s) + CCP_READY_TIMEOUT))
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
  if grep -qE '\(shift\+tab to cycle\)|\? for shortcuts' <<<"$P" ||
    grep -qE '^[[:space:]]*❯[[:space:]]*$' <<<"$P"; then
    ready=1
    break
  fi
  sleep 0.2
done

if [ "$ready" -ne 1 ]; then
  echo "ERROR: input box not ready within ${CCP_READY_TIMEOUT}s" >&2
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
#    CCP_ANSWER_TIMEOUT=0 waits forever — input complexity is unbounded, so there
#    is no sane fixed cap; the answer is whenever the model stops. Ctrl-C / kill
#    still tear everything down via the trap above. A session crash also breaks
#    the loop, so "forever" only ever means "until the model finishes or dies".
if [ "${CCP_ANSWER_TIMEOUT:-0}" -gt 0 ] 2>/dev/null; then
  adeadline=$(($(date +%s) + CCP_ANSWER_TIMEOUT))
else
  adeadline=0 # 0 = no deadline
fi
while [ "$adeadline" -eq 0 ] || [ "$(date +%s)" -lt "$adeadline" ]; do
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
  echo "ERROR: timed out after ${CCP_ANSWER_TIMEOUT}s waiting for the answer" >&2
  exit 1
fi
# 7) cleanup (kill tmux + rm RUNDIR) runs automatically via the trap set above,
#    covering normal exit, every `exit 1` path, and Ctrl-C / kill.
