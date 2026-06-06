#!/usr/bin/env bash
# PreToolUse hook: programmatically decide tool permissions so the interactive
# TUI never pops a y/n box (no capture-pane scraping needed).
#
# Usage (baked into --settings command line):
#   auto-perm.sh <allow|deny|ask>
#
# With a bare policy arg it applies that decision to every tool. It also reads
# stdin so the pipe never blocks, and lets a few obviously-dangerous Bash
# commands be denied even under an "allow" policy (defense in depth).
#
# Output schema (PreToolUse): hookSpecificOutput.permissionDecision.
# NOTE: the legacy `decision: approve/block` is dead for PreToolUse.
# NOTE: a hook `allow` cannot override a settings `permissions.deny` rule.
set -euo pipefail

POLICY="${1:-ask}"            # allow | deny | ask
INPUT="$(cat || true)"       # always drain stdin

DEC="$POLICY"

# Even under allow, hard-deny a couple of irreversible Bash footguns.
if [[ "$POLICY" == "allow" ]]; then
  TOOL="$(jq -r '.tool_name // ""' <<<"$INPUT" 2>/dev/null || echo "")"
  if [[ "$TOOL" == "Bash" ]]; then
    CMD="$(jq -r '.tool_input.command // ""' <<<"$INPUT" 2>/dev/null || echo "")"
    if grep -Eq 'rm[[:space:]]+-[a-z]*[rf]|mkfs|:\(\)\{|dd[[:space:]]+if=|>[[:space:]]*/dev/sd' <<<"$CMD"; then
      DEC="deny"
    fi
  fi
fi

jq -nc --arg d "$DEC" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: $d,
    permissionDecisionReason: ("auto-perm: " + $d)
  }
}'
