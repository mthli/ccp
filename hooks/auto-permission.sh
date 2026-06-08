#!/usr/bin/env bash
# PreToolUse hook: programmatically decide tool permissions so the interactive
# TUI never pops a y/n box (no capture-pane scraping needed).
#
# Usage (baked into --settings command line):
#   auto-permission.sh <allow|deny|ask> [askq-sentinel] [askq-msgfile]
#
# With a bare policy arg it applies that decision to every tool. It also reads
# stdin so the pipe never blocks, and lets a few obviously-dangerous Bash
# commands be denied even under an "allow" policy (defense in depth).
#
# AskUserQuestion needs an interactive human, which a detached headless run has
# not. In ALLOW mode it is denied (which suppresses the TUI's choice box — a plain
# allow only greenlights it and then the run hangs forever on the answer-wait) and
# the askq-sentinel is touched so the orchestrator aborts (exit 6); the question(s)
# are recorded to askq-msgfile for its message. In deny mode it is just denied like
# any other tool (the turn continues); in ask mode it defers to the TUI, since an
# attached human can answer it.
#
# Output schema (PreToolUse): hookSpecificOutput.permissionDecision.
# NOTE: the legacy `decision: approve/block` is dead for PreToolUse.
# NOTE: a hook `allow` cannot override a settings `permissions.deny` rule.
set -euo pipefail

POLICY="${1:-ask}"     # allow | deny | ask
ASKQ_FILE="${2:-}"     # sentinel touched when AskUserQuestion is seen (abort signal)
ASKQ_MSG="${3:-}"      # file to record the question text for ccp's abort message
INPUT="$(cat || true)" # always drain stdin

DEC="$POLICY"
TOOL="$(jq -r '.tool_name // ""' <<<"$INPUT" 2>/dev/null || echo "")"

# Abort the run on AskUserQuestion in allow mode (see header): deny it to suppress
# the box, record the question(s) + their options for the message FIRST, then touch
# the sentinel LAST so ccp never reads a half-written message.
if [[ "$TOOL" == "AskUserQuestion" && "$POLICY" == "allow" && -n "$ASKQ_FILE" ]]; then
  DEC="deny"
  if [[ -n "$ASKQ_MSG" ]]; then
    jq -r '.tool_input.questions[]?
             | "  - " + (.header // "question") + ": " + (.question // "")
               + ( if ((.options // []) | length) > 0
                   then "\n      options: " + ((.options // []) | map(.label // "?") | join(" / "))
                   else "" end )' \
      <<<"$INPUT" >"$ASKQ_MSG" 2>/dev/null || true
  fi
  : >"$ASKQ_FILE" 2>/dev/null || true
fi

# Even under allow, hard-deny a few irreversible Bash footguns. This is a
# best-effort heuristic, NOT a security boundary (the permission decision is) —
# it catches the common shapes of rm -rf / rm --recursive / rm --force, mkfs,
# fork bombs, dd-to-disk, and clobbering /dev/sd*, but is trivially evadable.
if [[ "$POLICY" == "allow" && "$TOOL" == "Bash" ]]; then
  CMD="$(jq -r '.tool_input.command // ""' <<<"$INPUT" 2>/dev/null || echo "")"
  if grep -Eq '\brm[[:space:]]+-[a-z]*[rf]|\brm[[:space:]]+--(recursive|force)|mkfs|:\(\)\{|dd[[:space:]]+if=|>[[:space:]]*/dev/sd' <<<"$CMD"; then
    DEC="deny"
  fi
fi

jq -nc --arg d "$DEC" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: $d,
    permissionDecisionReason: ("auto-permission: " + $d)
  }
}'
