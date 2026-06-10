#!/usr/bin/env bash
# StopFailure hook: the turn ended because of an API error (rate_limit, overloaded,
# billing_error, server_error, ...) instead of a normal response. StopFailure fires
# INSTEAD of Stop on this path, so dump-transcript.sh never runs and the orchestrator
# would block forever on the `done` sentinel that never arrives. Record the error
# type and drop a separate `fail` sentinel so ccp.sh can stop waiting and exit non-zero.
#
# Usage (baked into --settings command line):
#   dump-failure.sh <msg_file> <sentinel_file> [ccp_pid] [session]
#
# The optional pair drives the orphan self-destruct at the bottom — same contract
# as dump-transcript.sh: a failed turn is just as terminal as an answered one, so
# an orphaned session (ccp SIGKILLed) is reaped here too.
#
# StopFailure stdin carries .error_type — the same value its settings matcher filters
# on (one of: rate_limit, overloaded, authentication_failed, oauth_org_not_allowed,
# billing_error, invalid_request, model_not_found, server_error, max_output_tokens,
# unknown). We record it for ccp's error message. claude ignores this hook's output and
# exit code, so the files we write are the only effect.
set -euo pipefail

MSG="${1:?usage: dump-failure.sh <msg_file> <sentinel_file>}"
SENT="${2:?usage: dump-failure.sh <msg_file> <sentinel_file>}"

INPUT="$(cat || true)"
# .error_type is the documented field (StopFailure's matcher filters on it), but the
# exact stdin key isn't guaranteed, so probe a few plausible shapes and fall back to
# "unknown". A wrong field name only costs the label — the sentinel still drops, so the
# orchestrator still exits on the failure.
ETYPE="$(jq -r '[.error_type, .hookSpecificOutput.error_type, .error.type]
  | map(select(. != null and . != "")) | (.[0] // "unknown")' <<<"$INPUT" 2>/dev/null || echo "unknown")"
[ -n "$ETYPE" ] || ETYPE="unknown"

printf '%s\n' "$ETYPE" >"$MSG"
: >"$SENT" # touch sentinel LAST, so MSG is ready when SENT appears

# Orphan self-destruct (best-effort) — see dump-transcript.sh for the full story.
# StopFailure ends the turn for good (no later Stop is coming), so if the ccp
# that launched this run was SIGKILLed there is nobody left to read the fail
# sentinel or tear the session down; reap our own session. kill -0 probes
# liveness (same-user, so EPERM also means our ccp is gone); alive → teardown
# stays ccp's job. Args absent or malformed → no-op.
CCP_PID="${3:-}"
CCP_SESSION="${4:-}"
case "$CCP_PID" in '' | *[!0-9]*) exit 0 ;; esac
[ -n "$CCP_SESSION" ] || exit 0
if kill -0 "$CCP_PID" 2>/dev/null; then
  exit 0 # ccp alive — it reports the failure and kills the session via its trap
fi
# Reap the rundir too (no reader left; guarded on ccp's mktemp shape), then the
# session last — that kills claude and this hook with it. '=' pins the target to
# an exact name match — never tmux's prefix fallback.
RUNDIR="$(dirname "$SENT")"
case "$RUNDIR" in
*/cc-run.*) rm -rf "$RUNDIR" ;;
esac
tmux kill-session -t "=$CCP_SESSION" 2>/dev/null || true
