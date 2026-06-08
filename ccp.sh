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
#   CCP_SUBMIT_TIMEOUT    Seconds to keep resending Enter
#                         until the prompt submits            (default: 10)
#   CCP_ANSWER_TIMEOUT    Seconds to wait for the answer;
#                         0 = wait forever                    (default: 0)
#
# Exit codes:
#   0    success
#   1    runtime failure (session died, answer timeout, bad --settings)
#   2    usage/CLI error (bad args)
#   4    usage limit reached — quota/credit/429 block; claude is refusing further
#        requests until reset (https://code.claude.com/docs/en/errors#usage-limits)
#   5    turn failed via the StopFailure hook (an API error ended the turn)
#   6    turn needs interactive input — the model called AskUserQuestion, which a
#        detached headless run cannot answer (allow mode only; see step 5)
#   127  missing dependency or hook
#   130  interrupted (SIGINT) / 143 terminated (SIGTERM)
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
  -s, --session <name>      tmux session name for the run (default: cc-<pid>).
                            Must not contain '.' or ':'; must not already exist.
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
AUTO="allow"    # tool-permission mode: allow (default) | deny | ask
SESSION_NAME="" # -s/--session: tmux session name (unset → cc-<pid> default)
SESSION_SET=0   # whether -s/--session was given (to reject an explicit empty)
ENVS=()         # -e KEY=VALUE entries, injected via `tmux new-session -e`
PASSTHRU=()     # raw tokens after `--`, headed for claude

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
  -s | --session)
    [ "$#" -ge 2 ] || die "$1 requires a session name"
    SESSION_NAME="$2"
    SESSION_SET=1
    shift 2
    ;;
  --session=*)
    SESSION_NAME="${1#*=}"
    SESSION_SET=1
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
    die "unknown ccp option: $1 (ccp flags: -p, -s, -e, -h; claude options go after --)"
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

# Validate the -s session name when given: tmux rejects an empty name and any
# name containing '.' or ':' (its target-spec separators). When unset, the launch
# falls back to the unique cc-<pid> default below.
if [ "$SESSION_SET" -eq 1 ]; then
  [ -n "$SESSION_NAME" ] || die "-s/--session requires a non-empty session name"
  case "$SESSION_NAME" in
  *[.:]*) die "invalid -s session name '$SESSION_NAME' (must not contain '.' or ':')" ;;
  esac
fi

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
# hooks (not this script) — auto-permission can't emit a decision and dump-transcript
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

# Locate hooks/ beside this script. Resolve symlinks first: when installed via a
# Homebrew-style `bin/ccp -> libexec/ccp.sh` symlink, a bare `dirname "$0"` would
# point at bin/ (no hooks there) — follow the link chain to the real file instead.
SOURCE="${BASH_SOURCE[0]}"
while [ -L "$SOURCE" ]; do
  DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
  SOURCE="$(readlink "$SOURCE")"
  [[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE"
done
HOOK_DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)/hooks"

# Preflight the hooks too: they are as load-bearing as the deps above (auto-permission
# emits the permission decision, dump-transcript drives the done sentinel), and a
# missing or non-executable one fails silently mid-run — the TUI would block on a
# permission box, or the done sentinel would never appear, hanging us forever.
for hook in auto-permission.sh dump-transcript.sh dump-failure.sh; do
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
FAIL="$RUNDIR/fail"           # StopFailure sentinel: turn ended on an API error
FAILMSG="$RUNDIR/failmsg"     # the StopFailure error_type, for the message
ASKQ="$RUNDIR/askq"           # AskUserQuestion sentinel: turn needs interactive input
ASKQMSG="$RUNDIR/askqmsg"     # the AskUserQuestion question(s) text, for the message
SUBMITTED="$RUNDIR/submitted" # UserPromptSubmit sentinel: the prompt actually reached the model
SESSION="${SESSION_NAME:-cc-$$}"

# Tunables (override via env if the TUI wording ever changes).
CCP_READY_TIMEOUT="${CCP_READY_TIMEOUT:-60}"   # seconds to wait for the input box
CCP_SUBMIT_TIMEOUT="${CCP_SUBMIT_TIMEOUT:-10}" # seconds to confirm submit (resend Enter / re-paste) before giving up
CCP_ANSWER_TIMEOUT="${CCP_ANSWER_TIMEOUT:-0}"  # seconds to wait for the answer; 0 = forever

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

# Only kill the tmux session if WE started it (flipped on right after a successful
# `tmux new-session`). A user-supplied -s name can collide with a pre-existing
# session; without this guard, dying on that collision would tear down a session
# ccp never created.
SESSION_STARTED=0
cleanup() {
  if [ "$SESSION_STARTED" -eq 1 ]; then
    tmux kill-session -t "$SESSION" 2>/dev/null || true
  fi
  rm -rf "$RUNDIR"
}
# EXIT always cleans up. INT/TERM exit explicitly so Ctrl-C (or `kill`) unwinds
# through the EXIT trap once — removing the temp dir and tmux session — instead
# of running cleanup mid-loop and then continuing to poll.
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# 1) Temp settings: PreToolUse auto-permission + Stop transcript dump + StopFailure
#    failure trap. Hook paths are baked straight into the command lines (no env
#    smuggling through tmux); each is shell-quoted via shq so a path with spaces or
#    quotes survives when claude runs it.
#    StopFailure fires INSTEAD of Stop when the turn ends on an API error (rate_limit,
#    billing_error, overloaded, server_error, ...); without it those failures would
#    never drop the done sentinel and we'd block until the answer-timeout. We want it to
#    catch EVERY error_type, but the match-all convention for this event isn't verified
#    (the docs example matches a concrete type), so we register it two ways — matcher "*"
#    and no matcher at all — so whichever convention holds fires. If both do, dump-failure
#    just runs twice, which is idempotent (same sentinel files).
#    A fourth hook, UserPromptSubmit, just touches a `submitted` sentinel — it fires
#    only when a prompt actually reaches the model, which is how step 4 confirms the
#    submit landed (a paste mangled to whitespace is discarded with no UserPromptSubmit,
#    so the sentinel stays absent). It is an inline `touch ... || true` (the `|| true`
#    guarantees exit 0 so the hook can never block the prompt) and emits no stdout, so
#    it injects no context into the turn.
#    Any user `--settings` (file or JSON, repeatable) is deep-merged underneath, but
#    ccp's PreToolUse/Stop/StopFailure hooks always win: they ARE the mechanism
#    (auto-permission suppresses the y/n box, dump-transcript drives the done sentinel,
#    dump-failure drives the fail sentinel), so a user hook for any of those three
#    events is dropped while every other setting — including other hook events like
#    PostToolUse — is kept. ccp's UserPromptSubmit touch is the one exception that is
#    APPENDED rather than override: a user's own UserPromptSubmit hook still runs
#    alongside it (ours is purely additive — a file touch).
CCP_HOOKS="$(jq -n \
  --arg auto "$(shq "$HOOK_DIR/auto-permission.sh") $AUTO $(shq "$ASKQ") $(shq "$ASKQMSG")" \
  --arg stop "$(shq "$HOOK_DIR/dump-transcript.sh") $(shq "$OUT") $(shq "$DONE")" \
  --arg fail "$(shq "$HOOK_DIR/dump-failure.sh") $(shq "$FAILMSG") $(shq "$FAIL")" \
  '{
    PreToolUse: [{matcher: "*", hooks: [{type: "command", command: $auto}]}],
    Stop: [{hooks: [{type: "command", command: $stop}]}],
    StopFailure: [
      {matcher: "*", hooks: [{type: "command", command: $fail}]},
      {hooks: [{type: "command", command: $fail}]}
    ]
  }')"
# UserPromptSubmit is kept separate so it can be APPENDED to any user-supplied
# UserPromptSubmit hooks instead of overriding them (the three above must win, this
# one need not).
CCP_UPS="$(jq -n \
  --arg submit "touch $(shq "$SUBMITTED") || true" \
  '[{hooks: [{type: "command", command: $submit}]}]')"

if [ "${#USER_SETTINGS[@]}" -eq 0 ]; then
  jq -n --argjson ccp "$CCP_HOOKS" --argjson ups "$CCP_UPS" \
    '{hooks: ($ccp + {UserPromptSubmit: $ups})}' >"$SETTINGS"
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
    jq -s --argjson ccp "$CCP_HOOKS" --argjson ups "$CCP_UPS" '
      reduce .[] as $s ({}; . * $s)
      | .hooks = ((.hooks // {}) * $ccp)
      | .hooks.UserPromptSubmit = ((.hooks.UserPromptSubmit // []) + $ups)
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
# A user-supplied -s name can collide with an existing session. Bail before
# launching — and before SESSION_STARTED flips on — so cleanup never kills a
# session ccp didn't create. (The default cc-<pid> name is effectively unique.)
if tmux has-session -t "$SESSION" 2>/dev/null; then
  echo "ccp.sh: tmux session '$SESSION' already exists — pick another -s name or kill it first." >&2
  exit 1
fi
tmux new-session -d -s "$SESSION" -x 220 -y 50 \
  ${tmux_env[@]+"${tmux_env[@]}"} \
  "$claude_cmd"
SESSION_STARTED=1

# 3) Wait for the input box. Empirically the reliable signals are the mode hint
#    "(shift+tab to cycle)" / "? for shortcuts" and the empty prompt line; a
#    fresh/untrusted folder first shows a trust dialog we must dismiss. We do NOT
#    grep for "shortcuts" alone — a custom statusline can hide that hint.
pane() { tmux capture-pane -p -t "$SESSION" 2>/dev/null || true; }

# True if the pane shows a usage-limit / quota wall from the "Usage limits" section
# of https://code.claude.com/docs/en/errors. The subscription session/weekly/Opus
# walls make the TUI BLOCK further requests until reset without ending the turn — so
# no Stop and no StopFailure fires, and the answer-wait below would hang forever
# (default CCP_ANSWER_TIMEOUT=0). Credit-balance and 429 also land here as a backstop
# for claude builds without the StopFailure hook.
#
# This greps the STREAMING pane, which also holds the pasted prompt and the answer, so
# the patterns are anchored to the real error chrome to avoid firing on a prompt/answer
# that merely quotes a limit message: the walls require their "· resets <time>" tail and
# 429 requires its "API Error:" prefix. It stays a heuristic (a verbatim quote of the
# full message would still trip it, and a wording change would miss it — CCP_ANSWER_TIMEOUT
# is the escape hatch); this is the line to adjust if the TUI wording changes. Apostrophe-
# free so a straight vs. curly "You've" doesn't matter.
usage_limit_hit() {
  grep -qiE "hit your (session|weekly|opus) limit.*resets|Credit balance is too low|API Error: Request rejected \(429\)" <<<"$1"
}

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

# 4) Feed the prompt. -p wraps the buffer in bracketed-paste control codes so the
#    TUI ingests it as ONE paste (newlines stay literal text, never submits); -r
#    keeps LF as LF instead of the default LF->CR replacement (a bare CR is
#    byte-identical to Enter, so without -pr each newline reads as a submit and a
#    trailing newline + the real Enter get coalesced into the paste, so nothing
#    submits). The Enter(s) below land outside the bracket -> real submit.
printf '%s' "$PROMPT" | tmux load-buffer -b ccpaste -
tmux paste-buffer -pr -b ccpaste -t "$SESSION" -d

# Submit. The box going empty is NOT trusted as proof of submission: a single Enter
# can be swallowed (right after a big paste the TUI has a settle window that ignores a
# submit Enter — its "a paste ending in a newline must not auto-submit" guard), AND,
# worse, under CPU contention (e.g. two ccp sessions launched the same instant) a paste
# can land mangled to whitespace, which the TUI silently DISCARDS with no turn — also
# emptying the box. The old "empty == submitted" read then advanced to the answer-wait
# and hung forever on a turn that never started.
#
# So success is gated on GROUND TRUTH: the UserPromptSubmit hook's `submitted` sentinel
# (step 1), which fires (~tens of ms) only when a prompt really reaches the model and
# never on a discarded paste. While it is absent we keep nudging within CCP_SUBMIT_TIMEOUT
# — send Enter whenever the box shows content (the paste rendered), and if the box stays
# empty with no sentinel past a grace, the paste was dropped/discarded, so Ctrl-U (clear
# any residue) and re-paste. If the sentinel never lands, exit 1 rather than hang to
# CCP_ANSWER_TIMEOUT (default 0) — a clean, retryable failure instead of a silent wedge.
#
# The sentinel check sits at the top and breaks immediately, so a real submit (sentinel
# in ~tens of ms, measured ~66ms) always wins long before the ~3s re-paste grace — the
# grace is deliberately ~45x that latency so even a hook-dispatch stall under the same
# heavy contention that mangled the paste can't make us re-paste AFTER a real submit
# (which would queue the prompt as a second turn). The nudges therefore only ever act on
# a genuinely unsent box, so a resend/re-paste can never double-submit a live turn (and
# Ctrl-U makes the re-paste idempotent: a slow-rendering original paste cannot
# concatenate with the retry). Enter is only ever sent on a NON-empty box, so it never
# fires against the stale pre-paste empty frame, and never picks the default on an
# interactive menu (which auto-permission's AskUserQuestion deny prevents from rendering
# anyway, and which a turn could only reach long after the sentinel broke this loop).
submitted=0
empty_streak=0
sdeadline=$(($(date +%s) + CCP_SUBMIT_TIMEOUT))
while [ "$(date +%s)" -lt "$sdeadline" ]; do
  if ! tmux has-session -t "$SESSION" 2>/dev/null; then
    echo "ERROR: claude session died while submitting the prompt" >&2
    pane >&2
    exit 1
  fi
  # Ground truth: a prompt really reached the model.
  if [ -f "$SUBMITTED" ]; then
    submitted=1
    break
  fi
  if grep -qE '^[[:space:]]*❯[[:space:]]*$' <<<"$(pane)"; then
    # Box empty (or whitespace-only, which renders the same) and no sentinel. Could be
    # the stale pre-paste / still-rendering frame, or a discarded/dropped paste. Hold
    # for a grace, then re-paste — well past any real render lag, and a real submit's
    # sentinel would have broken the loop by now.
    empty_streak=$((empty_streak + 1))
    if [ "$empty_streak" -ge 15 ]; then # ~3s empty with no UserPromptSubmit -> re-paste
      tmux send-keys -t "$SESSION" C-u
      printf '%s' "$PROMPT" | tmux load-buffer -b ccpaste -
      tmux paste-buffer -pr -b ccpaste -t "$SESSION" -d
      empty_streak=0
    fi
    sleep 0.2
    continue
  fi
  # Box shows content: the paste rendered. (Re)send Enter to submit it — repeatedly if
  # the first is swallowed by the post-paste settle window (the box stays non-empty).
  # Safe to resend: the \r always trails the paste-end in byte order, so it can't get
  # coalesced into the paste.
  empty_streak=0
  tmux send-keys -t "$SESSION" Enter
  sleep 0.3
done
if [ "$submitted" -ne 1 ]; then
  echo "ERROR: prompt never submitted within ${CCP_SUBMIT_TIMEOUT}s (paste discarded or Enter swallowed)" >&2
  pane >&2
  exit 1
fi

# 5) Wait for the Stop hook to drop the done sentinel. The hook withholds it on
#    any intermediate Stop where a wake-capable backgrounded task is still running
#    (subagent / workflow / shell / teammate / cloud session — the kinds that wake
#    a follow-up turn with the real answer), so a turn that parks on one does not
#    end the run early — we wait for the Stop that fires once it completes and the
#    agent processes the result. A backgrounded shell wakes the agent on exit only
#    in an interactive session (which this is); every awaited type is held only
#    while running/pending, so a finished one never holds the run open. A monitor /
#    MCP task / dream is not awaited (it may fire on a condition or never finish).
#    CCP_ANSWER_TIMEOUT=0 waits forever — input complexity is unbounded, so there
#    is no sane fixed cap; the answer is whenever the model stops. Ctrl-C / kill
#    still tear everything down via the trap above. A session crash also breaks
#    the loop, so "forever" only ever means "until the model finishes or dies".
#    Three other escapes keep "forever" from being literal when no answer is coming:
#    the StopFailure hook's fail sentinel (an API error ended the turn), a
#    usage-limit wall in the pane (claude is blocking until reset, firing no hook),
#    and the AskUserQuestion sentinel (the turn needs interactive input we can't give).
# Report a StopFailure turn and exit 5. Shared by the wait loop and step 6: with a finite
# CCP_ANSWER_TIMEOUT a failure can land in the window between the deadline passing and the
# loop re-checking, so step 6 calls this too rather than mislabelling it as a timeout.
fail_exit() {
  local etype
  etype="$(cat "$FAILMSG" 2>/dev/null || true)"
  echo "ERROR: claude turn failed with an API error (StopFailure: ${etype:-unknown})" >&2
  exit 5
}

# Report an AskUserQuestion abort and exit 6. Like fail_exit, shared by the wait loop
# and step 6 so a question landing right at a finite-timeout deadline isn't mislabelled
# as a timeout. The sentinel is dropped by auto-permission, which also denied the tool
# so no choice box ever rendered; we surface the recorded question(s) so the caller can
# refine the prompt rather than guess why the run stopped.
askq_exit() {
  local q
  echo "ERROR: turn needs interactive input — the model called AskUserQuestion, which a" >&2
  echo "ccp.sh: detached headless run cannot answer." >&2
  q="$(cat "$ASKQMSG" 2>/dev/null || true)"
  if [ -n "$q" ]; then
    echo "ccp.sh: it asked:" >&2
    printf '%s\n' "$q" >&2
  fi
  echo "ccp.sh: refine the prompt so the model can decide without asking (or run attached" >&2
  echo "ccp.sh: with -p ask), then re-run." >&2
  exit 6
}

if [ "${CCP_ANSWER_TIMEOUT:-0}" -gt 0 ] 2>/dev/null; then
  adeadline=$(($(date +%s) + CCP_ANSWER_TIMEOUT))
else
  adeadline=0 # 0 = no deadline
fi
while [ "$adeadline" -eq 0 ] || [ "$(date +%s)" -lt "$adeadline" ]; do
  # Fail sentinel BEFORE the done sentinel: StopFailure is expected to fire instead of
  # Stop on an API error, but if a build ever fired both, preferring fail keeps a failed
  # turn from being reported as an empty success.
  [ -f "$FAIL" ] && fail_exit
  # AskUserQuestion before done: its sentinel is dropped mid-turn (the turn continues
  # after the deny, so a later Stop could still drop done) — surface the question and
  # abort rather than wait out a turn that needs input we can't give.
  [ -f "$ASKQ" ] && askq_exit
  [ -f "$DONE" ] && break
  # Usage-limit wall in the pane. Checked after the fail sentinel so a 429/billing error
  # that trips both is reported with its precise error_type — though a race (the wall is
  # on screen before dump-failure writes the sentinel) can still let this win, in which
  # case the run still exits non-zero, just as 4 rather than 5.
  if usage_limit_hit "$(pane)"; then
    echo "ERROR: usage limit reached — claude is blocking further requests until reset." >&2
    echo "ccp.sh: see https://code.claude.com/docs/en/errors#usage-limits (run 'claude' then /usage)." >&2
    exit 4
  fi
  if ! tmux has-session -t "$SESSION" 2>/dev/null; then
    echo "ERROR: claude session died before answering" >&2
    exit 1
  fi
  sleep 0.2
done

# 6) Emit result.
[ -f "$FAIL" ] && fail_exit # a failure that landed right at the deadline beats a timeout
[ -f "$ASKQ" ] && askq_exit # ditto an AskUserQuestion that landed right at the deadline
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
