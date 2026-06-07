#!/usr/bin/env bash
# StopFailure hook: the turn ended because of an API error (rate_limit, overloaded,
# billing_error, server_error, ...) instead of a normal response. StopFailure fires
# INSTEAD of Stop on this path, so dump-transcript.sh never runs and the orchestrator
# would block forever on the `done` sentinel that never arrives. Record the error
# type and drop a separate `fail` sentinel so ccp.sh can stop waiting and exit non-zero.
#
# Usage (baked into --settings command line):
#   dump-failure.sh <msg_file> <sentinel_file>
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
