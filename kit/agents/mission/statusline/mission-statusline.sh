#!/bin/bash
# mission-statusline.sh — opt-in Claude Code statusline. Shows live mission
# progress when the session cwd is inside a repo with an active mission/
# dir; a transparent passthrough (or minimal default) everywhere else.
# Enabled/disabled only via the kit repo's ./statusline.sh — never wired up
# by install.sh itself.
#
# Statusline contract verified against the official docs
# (https://code.claude.com/docs/en/statusline, fetched 2026-07-08):
#   - configured in ~/.claude/settings.json as
#     "statusLine": {"type": "command", "command": "<script-or-shell-cmd>"}
#   - the command receives ONE JSON object on stdin; the session cwd is
#     workspace.current_dir (documented as preferred; top-level cwd mirrors
#     it), the model name is model.display_name, session id is session_id
#   - every line printed to stdout renders as its own statusline row; this
#     script always renders the user's previous statusline first (or a
#     minimal default), then adds ONE mission row beneath it when the cwd
#     is inside a mission repo; ANSI color escapes are supported
#   - it runs after each assistant message, debounced at 300ms — so this
#     script must stay fast (a handful of jq calls, well under 100ms)
set -u

PREV_FILE="$HOME/.claude/mission-kit-statusline-prev.json"

INPUT="$(cat 2>/dev/null || true)"

# Resolve fields from the documented stdin JSON, tolerating empty or
# malformed input — a statusline must never error out.
CWD="$(printf '%s' "$INPUT" | jq -r '.workspace.current_dir // .cwd // empty' 2>/dev/null || true)"
MODEL="$(printf '%s' "$INPUT" | jq -r '.model.display_name // empty' 2>/dev/null || true)"

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

# --- No mission → nothing to add below the normal bar -----------------------
[ -z "$MISSION_DIR" ] && exit 0

# --- Mission found → add ONE mission row below the normal bar ---------------
# All reads tolerate missing/partial files: a mission mid-write must never
# crash the bar — worst case the mission row is simply omitted this refresh.
CUR_ID=""
if [ -f "$MISSION_DIR/.current-feature" ]; then
  bl="$(head -n 1 "$MISSION_DIR/.current-feature" 2>/dev/null || true)"
  cid="${bl#*|}"
  [ "$cid" != "$bl" ] && [ -n "$cid" ] && CUR_ID="$cid"
fi

STATS="$(jq -r --arg cid "$CUR_ID" '
  .features as $f
  | ([$f[] | select(.id == $cid)] | first) as $cur
  | [
      ($f | length),
      ([$f[] | select(.status == "passed" or .status == "completed")] | length),
      ([$f[] | select(.kind == "fix" and .status == "pending")] | length),
      (if ([$f[] | select(.status != "passed" and .status != "blocked")] | length) == 0
       then 1 else 0 end),
      ($cur.kind // "-"),
      ($cur.attempts // 0)
    ]
  | @tsv
' "$MISSION_DIR/features.json" 2>/dev/null || true)"

# Base row already printed; on unreadable state just skip the mission row.
[ -z "$STATS" ] && exit 0

IFS=$'\t' read -r TOTAL DONE FIXES COMPLETE KIND ATTEMPTS <<EOF
$STATS
EOF

# Compact 5-cell progress bar.
FILLED=0
[ "$TOTAL" -gt 0 ] 2>/dev/null && FILLED=$((DONE * 5 / TOTAL))
BAR=""
j=0
while [ "$j" -lt 5 ]; do
  if [ "$j" -lt "$FILLED" ]; then BAR="${BAR}▓"; else BAR="${BAR}░"; fi
  j=$((j + 1))
done

DIM=$'\033[2m'
GREEN=$'\033[32m'
RESET=$'\033[0m'

if [ "$COMPLETE" = "1" ]; then
  printf '%s▣ %s/%s %s · ✔ mission complete%s\n' "$GREEN" "$DONE" "$TOTAL" "$BAR" "$RESET"
  exit 0
fi

LINE="▣ ${DONE}/${TOTAL} ${BAR}"

if [ -n "$CUR_ID" ]; then
  case "$KIND" in
    implementation) KLABEL="worker" ;;
    scrutiny)       KLABEL="scrutiny" ;;
    flow-validation) KLABEL="flow" ;;
    fix)            KLABEL="fix" ;;
    *)              KLABEL="agent" ;;
  esac
  # Elapsed since the breadcrumb was written (its mtime).
  EL=""
  mt="$(stat -f %m "$MISSION_DIR/.current-feature" 2>/dev/null \
     || stat -c %Y "$MISSION_DIR/.current-feature" 2>/dev/null || true)"
  if [ -n "$mt" ]; then
    s=$(($(date +%s) - mt))
    [ "$s" -lt 0 ] && s=0
    if [ "$s" -lt 3600 ]; then EL=" $((s / 60))m"
    else EL=" $((s / 3600))h$(((s % 3600) / 60))m"; fi
  fi
  RETRY=""
  [ "$ATTEMPTS" -gt 1 ] 2>/dev/null && RETRY=", retry ${ATTEMPTS}/3"
  LINE="$LINE · ${CUR_ID} (${KLABEL}${EL}${RETRY})"
else
  LINE="$LINE ${DIM}· idle${RESET}"
fi

if [ "$FIXES" -gt 0 ] 2>/dev/null; then
  if [ "$FIXES" -eq 1 ]; then LINE="$LINE · 1 fix queued"
  else LINE="$LINE · ${FIXES} fixes queued"; fi
fi

printf '%s\n' "$LINE"
exit 0
