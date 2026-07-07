#!/bin/bash
# mission-statusline.sh — opt-in Claude Code statusline. Renders the user's
# previous statusline first (or a minimal default), then adds ONE mission
# row beneath it — but only in the session that is actually running the
# mission (see the session gate below). Enabled/disabled only via the kit
# repo's ./statusline.sh — never wired up by install.sh itself.
#
# Statusline contract verified against the official docs
# (https://code.claude.com/docs/en/statusline, fetched 2026-07-08):
#   - configured in ~/.claude/settings.json as
#     "statusLine": {"type": "command", "command": "<script-or-shell-cmd>"}
#   - the command receives ONE JSON object on stdin; the session cwd is
#     workspace.current_dir (documented as preferred; top-level cwd mirrors
#     it), the model name is model.display_name, the session's transcript
#     file is transcript_path, session id is session_id
#   - every line printed to stdout renders as its own statusline row;
#     ANSI color escapes are supported
#   - it runs after each assistant message, debounced at 300ms — so this
#     script must stay fast (a handful of jq calls, well under 100ms)
#
# SESSION GATE: the mission row must appear only in the session where
# /mission-run is executing — not in other sessions that merely have their
# cwd inside the same repo. There is no session-id handshake available (the
# orchestrator cannot learn its own session id), so the gate is: the
# session transcript (transcript_path from stdin) contains the mission-run
# goal condition text "stop after 150 turns" — a string injected into the
# transcript only when the /mission-run skill is loaded. No transcript, or
# no marker → no mission row.
set -u

PREV_FILE="$HOME/.claude/mission-kit-statusline-prev.json"
RUNNER_MARKER="stop after 150 turns"

INPUT="$(cat 2>/dev/null || true)"

# Resolve fields from the documented stdin JSON, tolerating empty or
# malformed input — a statusline must never error out.
CWD="$(printf '%s' "$INPUT" | jq -r '.workspace.current_dir // .cwd // empty' 2>/dev/null || true)"
MODEL="$(printf '%s' "$INPUT" | jq -r '.model.display_name // empty' 2>/dev/null || true)"
TRANSCRIPT="$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null || true)"

render_base() {
  # The user's normal statusline, always rendered first: the command that
  # was in settings.json before enable (run with the original stdin piped
  # through, same as Claude Code would run it), or a minimal default so
  # the user never gets a blank bar.
  if [ -f "$PREV_FILE" ]; then
    PREV_CMD="$(jq -r '.statusLine.command // empty' "$PREV_FILE" 2>/dev/null || true)"
    if [ -n "$PREV_CMD" ]; then
      # Re-emit with a guaranteed trailing newline: if the previous command
      # prints without one, the mission row would otherwise be glued onto
      # the same row. Falls through to the default if it prints nothing.
      prev_out="$(printf '%s' "$INPUT" | /bin/sh -c "$PREV_CMD" 2>/dev/null || true)"
      if [ -n "$prev_out" ]; then
        printf '%s\n' "$prev_out"
        return 0
      fi
    fi
  fi
  base="${CWD##*/}"
  [ -n "$base" ] || base="claude"
  if [ -n "$MODEL" ]; then
    printf '%s · %s\n' "$base" "$MODEL"
  else
    printf '%s\n' "$base"
  fi
}

# --- Locate mission/features.json by walking up from cwd (max 10 levels) ----
MISSION_DIR=""
dir="$CWD"
i=0
while [ -n "$dir" ] && [ "$i" -lt 10 ]; do
  if [ -f "$dir/mission/features.json" ]; then
    MISSION_DIR="$dir/mission"
    break
  fi
  [ "$dir" = "/" ] && break
  dir="$(dirname "$dir")"
  i=$((i + 1))
done

# The user's normal statusline always renders, mission or not.
render_base

# --- No mission in cwd → nothing to add below the normal bar ----------------
[ -z "$MISSION_DIR" ] && exit 0

# --- Session gate: only the mission-running session gets the row ------------
[ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ] || exit 0
grep -q -m 1 -F "$RUNNER_MARKER" "$TRANSCRIPT" 2>/dev/null || exit 0

# --- Mission row: read state (tolerate missing/partial files) ---------------
# A mission mid-write must never crash the bar — worst case the mission row
# is simply omitted for this refresh.
CUR_ID=""
if [ -f "$MISSION_DIR/.current-feature" ]; then
  bl="$(head -n 1 "$MISSION_DIR/.current-feature" 2>/dev/null || true)"
  cid="${bl#*|}"
  [ "$cid" != "$bl" ] && [ -n "$cid" ] && CUR_ID="$cid"
fi

STATS="$(jq -r --arg cid "$CUR_ID" '
  .features as $f
  | ([$f[] | select(.id == $cid)] | first) as $cur
  | ($cur.milestone // "") as $ms
  | [
      ($f | length),
      ([$f[] | select(.status == "passed" or .status == "completed")] | length),
      ([$f[] | select(.kind == "fix" and .status == "pending")] | length),
      ([$f[] | select(.status == "blocked")] | length),
      (if ([$f[] | select(.status != "passed" and .status != "blocked")] | length) == 0
       then 1 else 0 end),
      ($cur.kind // "-"),
      ($cur.attempts // 0),
      (if $ms != "" then ([$f[] | select(.milestone == $ms
          and (.status == "passed" or .status == "completed"))] | length) else -1 end),
      (if $ms != "" then ([$f[] | select(.milestone == $ms)] | length) else -1 end),
      (if $ms != "" then ($ms | tostring) else "-" end)
    ]
  | @tsv
' "$MISSION_DIR/features.json" 2>/dev/null || true)"

# Base row already printed; on unreadable state just skip the mission row.
[ -z "$STATS" ] && exit 0

IFS=$'\t' read -r TOTAL DONE FIXES BLOCKED COMPLETE KIND ATTEMPTS MS_DONE MS_TOTAL MS <<EOF
$STATS
EOF

# --- Mission total running time (since the first logged event) --------------
run_segment() {
  pl="$MISSION_DIR/progress_log.jsonl"
  [ -s "$pl" ] || return 0
  ts="$(head -n 1 "$pl" | jq -r '.timestamp // empty' 2>/dev/null || true)"
  [ -n "$ts" ] || return 0
  t="${ts%%.*}"
  t="${t%Z}"
  # GNU date first, BSD date fallback (macOS ships BSD date).
  start="$(date -u -d "$ts" +%s 2>/dev/null \
        || date -ju -f "%Y-%m-%dT%H:%M:%S" "$t" +%s 2>/dev/null || true)"
  [ -n "$start" ] || return 0
  s=$(($(date +%s) - start))
  [ "$s" -lt 0 ] && return 0
  if [ "$s" -lt 3600 ]; then
    printf 'RUN %dm' $((s / 60))
  else
    printf 'RUN %dh%02dm' $((s / 3600)) $(((s % 3600) / 60))
  fi
}

fmt_elapsed() {
  # fmt_elapsed <file> — minutes/hours since the file's mtime.
  mt="$(stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || true)"
  [ -n "$mt" ] || return 0
  s=$(($(date +%s) - mt))
  [ "$s" -lt 0 ] && s=0
  if [ "$s" -lt 3600 ]; then printf '%dm' $((s / 60))
  else printf '%dh%02dm' $((s / 3600)) $(((s % 3600) / 60)); fi
}

# --- Assemble the brutalist row ----------------------------------------------
# One saturated chip as the anchor, everything else typographic. The bar is
# bracketed like Claude Code's own context bar in the row above, so the two
# rows read as one instrument panel. Accents: yellow = mission brand (chip
# + bar fill), cyan = milestone, green = play marker, orange = the agent
# working right now, red = retries/blocked, green chip = complete.
BOLD=$'\033[1m'
DIM=$'\033[2m'
GRAY=$'\033[38;5;242m'
DARK=$'\033[38;5;237m'
RESET=$'\033[0m'
BAR_FG=$'\033[38;2;175;175;94m'      # #AFAF5E (truecolor; bar fill + %)
CYAN_FG=$'\033[1;38;5;45m'
GREEN_FG=$'\033[1;38;5;46m'
ORANGE_FG=$'\033[1;38;5;214m'
RED_FG=$'\033[1;38;5;196m'
CHIP_BRAND=$'\033[1;97;48;5;202m'    # white on #FF5F00 (256-color 202 is exact)
CHIP_GREEN=$'\033[1;30;48;5;46m'     # black on green
SEP="  ${DARK}│${RESET}  "

FILLED=0
[ "$TOTAL" -gt 0 ] 2>/dev/null && FILLED=$((DONE * 10 / TOTAL))
PCT=0
[ "$TOTAL" -gt 0 ] 2>/dev/null && PCT=$((DONE * 100 / TOTAL))
FILL=""
EMPTY=""
j=0
while [ "$j" -lt 10 ]; do
  if [ "$j" -lt "$FILLED" ]; then FILL="${FILL}█"; else EMPTY="${EMPTY}░"; fi
  j=$((j + 1))
done
BAR="${GRAY}[${RESET}${BAR_FG}${FILL}${RESET}${DARK}${EMPTY}${RESET}${GRAY}]${RESET}"

RUNSEG="$(run_segment)"

if [ "$COMPLETE" = "1" ]; then
  LINE="${CHIP_GREEN} ✔ MISSION COMPLETE ${RESET} ${BOLD}${DONE}/${TOTAL}${RESET} ${BAR}"
  [ "$BLOCKED" -gt 0 ] 2>/dev/null && LINE="${LINE}${SEP}${RED_FG}${BLOCKED} BLOCKED${RESET}"
  [ -n "$RUNSEG" ] && LINE="${LINE}${SEP}${GRAY}${RUNSEG}${RESET}"
  printf '%s\n' "$LINE"
  exit 0
fi

LINE="${CHIP_BRAND} MISSION ${RESET} ${BOLD}${DONE}/${TOTAL}${RESET} ${BAR} ${BAR_FG}${PCT}%${RESET}"

# Milestone-local progress (only when a feature is running and carries one).
if [ "$MS" != "-" ] && [ "$MS_TOTAL" -gt 0 ] 2>/dev/null; then
  msname="$MS"
  case "$msname" in m*|M*) msname="${msname#m}"; msname="${msname#M}" ;; esac
  LINE="${LINE}${SEP}${CYAN_FG}M${msname}${RESET} ${MS_DONE}${GRAY}/${MS_TOTAL}${RESET}"
fi

if [ -n "$CUR_ID" ]; then
  case "$KIND" in
    implementation)  KLABEL="WORKER" ;;
    scrutiny)        KLABEL="SCRUTINY" ;;
    flow-validation) KLABEL="FLOW" ;;
    fix)             KLABEL="FIX" ;;
    *)               KLABEL="AGENT" ;;
  esac
  EL="$(fmt_elapsed "$MISSION_DIR/.current-feature")"
  CURSEG="${GREEN_FG}▶${RESET} ${BOLD}${CUR_ID}${RESET} ${GRAY}·${RESET} ${ORANGE_FG}${KLABEL}${EL:+ $EL}${RESET}"
  [ "$ATTEMPTS" -gt 1 ] 2>/dev/null && CURSEG="${CURSEG} ${GRAY}·${RESET} ${RED_FG}RETRY ${ATTEMPTS}/3${RESET}"
  LINE="${LINE}${SEP}${CURSEG}"
else
  LINE="${LINE}${SEP}${GRAY}IDLE${RESET}"
fi

[ -n "$RUNSEG" ] && LINE="${LINE}${SEP}${GRAY}${RUNSEG}${RESET}"
[ "$FIXES" -gt 0 ] 2>/dev/null && LINE="${LINE}${SEP}${ORANGE_FG}${FIXES} FIX${RESET}"
[ "$BLOCKED" -gt 0 ] 2>/dev/null && LINE="${LINE}${SEP}${RED_FG}${BLOCKED} BLOCKED${RESET}"

printf '%s\n' "$LINE"
exit 0
