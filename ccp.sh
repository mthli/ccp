#!/usr/bin/env bash
#
# ccp.sh — run Claude Code headlessly on the subscription pool
# ============================================================
#
# Drives an INTERACTIVE Claude Code TUI inside a detached tmux session as if it
# were `claude -p`, so usage bills against the subscription pool instead of the
# Agent SDK credit pool. The clean final assistant text is printed to stdout.
#
# Run `./ccp.sh --help` for the CLI surface (args, flags, example) — that is the
# single source of truth; see usage() below.
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
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ccp.sh [ccp-options] "<prompt>" [-- <claude-options>...]

Arguments:
  <prompt>                  Prompt to send (required; quote multi-line prompts).
                            Must appear before `--`.

ccp options (before `--`):
  -p, --permission <mode>   Tool-permission mode: allow (default) | deny | ask.
  -e, --env KEY=VALUE       Set an env var for the launched session, injected via
                            `tmux new-session -e` (repeatable). claude and every
                            hook/subprocess it runs inherit it.
  -h, --help                Show this help and exit.

claude passthrough (after `--`):
  Everything after `--` is forwarded verbatim to the underlying `claude`, so you
  can use claude's own options (--model, --add-dir, --mcp-config, ...). Two are
  handled by ccp instead of being passed through:
    --settings <file|json>  Deep-merged into ccp's generated settings
                            (repeatable); ccp's own PreToolUse/Stop hooks win.
    -p, --print             Ignored with a warning — claude's headless mode is
                            unsupported (ccp drives an interactive session and
                            prints the final answer itself). Use ccp's own
                            -p/--permission for the tool-permission mode.

Examples:
  ccp.sh "summarize README.md"
  ccp.sh -p deny "scan the repo" -- --model opus --add-dir /tmp
  ccp.sh "review" -- --settings ./my-settings.json --mcp-config ./mcp.json
EOF
}

# Print a message + usage on stderr and exit 2 (usage error).
die() {
  {
    echo "ccp.sh: $1"
    echo
    usage
  } >&2
  exit 2
}

# Single-quote a string for safe reuse in a shell command line (tmux runs the
# claude command via the shell). Embedded single quotes become the '\'' idiom,
# so any path/arg — spaces, $, quotes — survives verbatim.
shq() {
  local q="'\''"
  printf "'%s'" "${1//\'/$q}"
}

# Parse args. Before `--`: ccp's own flags + the sole positional prompt (a bare
# value like "deny" is unambiguously the prompt, not a mode). `--` switches to
# claude passthrough — every following token is collected verbatim and forwarded
# to `claude` (the scan further down peels off the two flags ccp handles itself).
PROMPT=""
PROMPT_SET=0
AUTO="allow" # tool-permission mode: allow (default) | deny | ask
ENVS=()      # -e KEY=VALUE entries, injected via `tmux new-session -e`
PASSTHRU=()  # raw tokens after `--`, headed for claude

set_prompt() {
  [ "$PROMPT_SET" -eq 0 ] || die "unexpected extra argument: $1 (claude options go after --)"
  PROMPT="$1"
  PROMPT_SET=1
}

while [ "$#" -gt 0 ]; do
  case "$1" in
  -h | --help)
    usage
    exit 0
    ;;
  -p | --permission)
    [ "$#" -ge 2 ] || die "$1 requires a value (allow|deny|ask)"
    AUTO="$2"
    shift 2
    ;;
  --permission=*)
    AUTO="${1#*=}"
    shift
    ;;
  -e | --env)
    [ "$#" -ge 2 ] || die "$1 requires KEY=VALUE"
    ENVS+=("$2")
    shift 2
    ;;
  --env=*)
    ENVS+=("${1#*=}")
    shift
    ;;
  -e?*)
    ENVS+=("${1#-e}") # glued short form: -eKEY=VALUE
    shift
    ;;
  --)
    shift
    # Everything after `--` is claude passthrough; collect it untouched.
    while [ "$#" -gt 0 ]; do
      PASSTHRU+=("$1")
      shift
    done
    break
    ;;
  -?*)
    die "unknown ccp option: $1 (ccp flags: -p, -e, -h; claude options go after --)"
    ;;
  *)
    set_prompt "$1"
    shift
    ;;
  esac
done

{ [ "$PROMPT_SET" -eq 1 ] && [ -n "$PROMPT" ]; } || die "missing required <prompt> argument"

case "$AUTO" in
allow | deny | ask) ;;
*) die "invalid permission mode '$AUTO' (expected: allow, deny, or ask)" ;;
esac

# Validate each -e entry as NAME=VALUE with a sane variable name, since it is
# passed straight to `tmux new-session -e`.
if [ "${#ENVS[@]}" -gt 0 ]; then
  for kv in "${ENVS[@]}"; do
    case "$kv" in
    [A-Za-z_]*=*) ;;
    *) die "invalid -e value '$kv' (expected NAME=VALUE)" ;;
    esac
    case "${kv%%=*}" in
    *[!A-Za-z0-9_]*) die "invalid -e variable name '${kv%%=*}' (use letters, digits, underscore)" ;;
    esac
  done
fi

# Split the claude passthrough into args forwarded verbatim and the two flags ccp
# handles itself: `--settings` (deep-merged into ccp's generated settings, so the
# hooks survive) and `-p`/`--print` (claude's headless mode — unsupported, since
# ccp drives an interactive session and prints the answer itself). A linear walk
# suffices: both flags are recognizable by name, so we never need to know the
# arity of the other claude options we pass straight through. (Caveat: a bare
# `--settings`/`-p`/`--print` is intercepted even in the rare case it's meant as
# the value of a preceding claude flag — name matching can't tell the two apart.)
CLAUDE_ARGS=()   # forwarded to claude verbatim
USER_SETTINGS=() # --settings values (file path or JSON string), merged below
print_warned=0
i=0
while [ "$i" -lt "${#PASSTHRU[@]}" ]; do
  tok="${PASSTHRU[$i]}"
  case "$tok" in
  --settings)
    j=$((i + 1))
    [ "$j" -lt "${#PASSTHRU[@]}" ] || die "--settings requires a value (file path or JSON string)"
    USER_SETTINGS+=("${PASSTHRU[$j]}")
    i=$((i + 2))
    ;;
  --settings=*)
    USER_SETTINGS+=("${tok#*=}")
    i=$((i + 1))
    ;;
  -p | --print)
    if [ "$print_warned" -eq 0 ]; then
      echo "ccp.sh: ignoring '$tok' — claude's -p/--print (headless) is unsupported." >&2
      echo "ccp.sh: ccp drives an interactive session and prints the final answer itself;" >&2
      echo "ccp.sh: use ccp's own -p/--permission for the tool-permission mode." >&2
      print_warned=1
    fi
    i=$((i + 1))
    ;;
  *)
    CLAUDE_ARGS+=("$tok")
    i=$((i + 1))
    ;;
  esac
done

# Preflight: every hard dependency must be on PATH. Checked up front so a missing
# tool fails with one clear line instead of failing deep in the run: tmux would
# abort at `tmux new-session` with a raw "command not found", while jq breaks the
# hooks (not this script) — auto-perm can't emit a decision and dump-transcript
# silently yields an empty answer, neither of which points at the real cause.
missing=""
for dep in tmux jq claude; do
  command -v "$dep" >/dev/null 2>&1 || missing="$missing $dep"
done
if [ -n "$missing" ]; then
  echo "ccp.sh: missing required dependencies: $missing" >&2
  echo "ccp.sh: install them and re-run (deps: tmux, jq, claude)." >&2
  exit 127
fi

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)/hooks"

# Preflight the hooks too: they are as load-bearing as the deps above (auto-perm
# emits the permission decision, dump-transcript drives the done sentinel), and a
# missing or non-executable one fails silently mid-run — the TUI would block on a
# permission box, or the done sentinel would never appear, hanging us forever.
for hook in auto-perm.sh dump-transcript.sh; do
  if [ ! -x "$HOOK_DIR/$hook" ]; then
    echo "ccp.sh: required hook not found or not executable: $HOOK_DIR/$hook" >&2
    echo "ccp.sh: ensure hooks/ sits beside ccp.sh and is executable (chmod +x)." >&2
    exit 127
  fi
done

RUNDIR="$(mktemp -d -t cc-run.XXXXXX)"
SETTINGS="$RUNDIR/settings.json"
OUT="$RUNDIR/output.txt"
DONE="$RUNDIR/done"
SESSION="cc-$$"

# Tunables (override via env if the TUI wording ever changes).
CCP_READY_TIMEOUT="${CCP_READY_TIMEOUT:-60}"  # seconds to wait for the input box
CCP_ANSWER_TIMEOUT="${CCP_ANSWER_TIMEOUT:-0}" # seconds to wait for the answer; 0 = forever

# `ask` defers each tool call to the TUI's permission box, but this session is
# detached — no one is there to answer it. Combined with the default forever
# answer-timeout, an `ask` run that hits a tool call hangs silently. Warn and
# point at the attach path. (`! [ x -gt 0 ]` is true for 0 and non-numeric — the
# same "effectively forever" test the answer-wait loop uses below.)
if [ "$AUTO" = "ask" ] && ! [ "$CCP_ANSWER_TIMEOUT" -gt 0 ] 2>/dev/null; then
  echo "ccp.sh: note: -p ask defers tool permissions to the TUI, but this session is" >&2
  echo "ccp.sh: detached — attach with 'tmux attach -t $SESSION' to answer prompts," >&2
  echo "ccp.sh: or it waits forever (set CCP_ANSWER_TIMEOUT to bound the wait)." >&2
fi

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

# 1) Temp settings: PreToolUse auto-permission + Stop transcript dump. Hook paths
#    are baked straight into the command lines (no env smuggling through tmux);
#    each is shell-quoted via shq so a path with spaces or quotes survives when
#    claude runs it.
#    Any user `--settings` (file or JSON, repeatable) is deep-merged underneath,
#    but ccp's PreToolUse/Stop hooks always win: they ARE the mechanism (auto-perm
#    suppresses the y/n box, dump-transcript drives the done sentinel), so a user
#    hook for either of those two events is dropped while every other setting —
#    including other hook events like PostToolUse — is kept.
CCP_HOOKS="$(jq -n \
  --arg auto "$(shq "$HOOK_DIR/auto-perm.sh") $AUTO" \
  --arg stop "$(shq "$HOOK_DIR/dump-transcript.sh") $(shq "$OUT") $(shq "$DONE")" \
  '{
    PreToolUse: [{matcher: "*", hooks: [{type: "command", command: $auto}]}],
    Stop: [{hooks: [{type: "command", command: $stop}]}]
  }')"

if [ "${#USER_SETTINGS[@]}" -eq 0 ]; then
  jq -n --argjson ccp "$CCP_HOOKS" '{hooks: $ccp}' >"$SETTINGS"
else
  # Resolve each --settings value (existing path → file contents, else treat as
  # an inline JSON string, matching claude's own rule), validate, then deep-merge
  # in order (later wins) and overlay ccp's hooks last.
  merge_inputs=()
  for s in "${USER_SETTINGS[@]}"; do
    if [ -f "$s" ]; then
      content="$(cat "$s")"
      label="file '$s'"
    else
      content="$s"
      label="inline JSON"
    fi
    jq empty >/dev/null 2>&1 <<<"$content" || {
      echo "ccp.sh: invalid --settings ($label): not valid JSON" >&2
      exit 1
    }
    merge_inputs+=("$content")
  done
  printf '%s\n' "${merge_inputs[@]}" |
    jq -s --argjson ccp "$CCP_HOOKS" '
      reduce .[] as $s ({}; . * $s)
      | .hooks = ((.hooks // {}) * $ccp)
    ' >"$SETTINGS"
fi

# 2) Launch interactive claude in a detached tmux session. Each -e KEY=VALUE is
#    injected via `tmux new-session -e`, which writes straight into the new
#    session's environment (claude and every hook/subprocess it runs inherit it)
#    — unlike ambient inheritance, it lands regardless of whether a tmux server
#    is already running. One use: a guard var that silences a global Stop hook
#    re-entering `claude -p`, which would otherwise bill the Agent SDK pool.
tmux_env=()
if [ "${#ENVS[@]}" -gt 0 ]; then
  for kv in "${ENVS[@]}"; do tmux_env+=(-e "$kv"); done
fi
# Build the claude command line: always our merged --settings, then any
# passthrough args (each shell-quoted so spaces/specials survive the shell tmux
# runs it through). No positional prompt — claude launches interactive and the
# prompt is pasted in step 4.
claude_cmd="claude --settings $(shq "$SETTINGS")"
if [ "${#CLAUDE_ARGS[@]}" -gt 0 ]; then
  for a in "${CLAUDE_ARGS[@]}"; do
    claude_cmd="$claude_cmd $(shq "$a")"
  done
fi
tmux new-session -d -s "$SESSION" -x 220 -y 50 \
  ${tmux_env[@]+"${tmux_env[@]}"} \
  "$claude_cmd"

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
  # An empty answer (the turn ended with no final text — e.g. a trailing tool
  # call) prints as nothing and exits 0, indistinguishable from success; flag it
  # on stderr so the caller can tell "no answer" apart from a real empty one.
  grep -q '[^[:space:]]' "$OUT" || echo "ccp.sh: warning: model produced no final text (empty answer)" >&2
else
  echo "ERROR: timed out after ${CCP_ANSWER_TIMEOUT}s waiting for the answer" >&2
  exit 1
fi
# 7) cleanup (kill tmux + rm RUNDIR) runs automatically via the trap set above,
#    covering normal exit, every `exit 1` path, and Ctrl-C / kill.
