#!/bin/bash
# statusline.sh — opt-in enable/disable/status for the mission statusline.
#
# This is the ONE sanctioned settings.json interaction in the kit, and it
# exists only behind this explicit user opt-in: `./install.sh` never touches
# settings.json. `enable` saves the current .statusLine value (and a byte
# backup of settings.json) so `disable` can restore it exactly:
#   ~/.claude/mission-kit-statusline-prev.json          (saved statusLine)
#   ~/.claude/mission-kit-statusline-prev-settings.bak  (byte backup)
# Both exist only while enabled; disable and uninstall.sh remove them.
# No other settings.json key is ever read or written.
set -u

DEST="$HOME/.claude"
SETTINGS="$DEST/settings.json"
PREV_FILE="$DEST/mission-kit-statusline-prev.json"
BAK_FILE="$DEST/mission-kit-statusline-prev-settings.bak"
SCRIPT_INSTALLED="$DEST/agents/mission/statusline/mission-statusline.sh"
# Written into settings.json verbatim; the shell tilde-expands it at
# statusline runtime (the documented example uses the same form).
CMD_STRING="~/.claude/agents/mission/statusline/mission-statusline.sh"

usage() {
  echo "usage: ./statusline.sh enable|disable|status" >&2
  exit 1
}
[ "$#" -eq 1 ] || usage

# write_settings <json-string>: atomic same-directory replace of settings.json.
write_settings() {
  tmpf="$(mktemp "$DEST/.statusline-tmp.XXXXXX")" || exit 1
  printf '%s\n' "$1" > "$tmpf" || { rm -f "$tmpf"; exit 1; }
  mv "$tmpf" "$SETTINGS" || exit 1
}

find_mission() {
  d="$PWD"
  i=0
  while [ -n "$d" ] && [ "$i" -lt 10 ]; do
    if [ -f "$d/mission/features.json" ]; then
      echo "$d/mission"
      return 0
    fi
    [ "$d" = "/" ] && break
    d="$(dirname "$d")"
    i=$((i + 1))
  done
  return 1
}

case "$1" in
  enable)
    if [ -e "$PREV_FILE" ]; then
      echo "statusline.sh: already enabled ($PREV_FILE exists) — run './statusline.sh disable' first" >&2
      exit 1
    fi
    if [ ! -x "$SCRIPT_INSTALLED" ]; then
      echo "statusline.sh: $SCRIPT_INSTALLED missing or not executable — run ./install.sh first" >&2
      exit 1
    fi
    if [ -f "$SETTINGS" ]; then
      if ! jq empty "$SETTINGS" >/dev/null 2>&1; then
        echo "statusline.sh: $SETTINGS is not valid JSON — refusing to modify it" >&2
        exit 1
      fi
      SAVED="$(jq '.statusLine // null' "$SETTINGS")" || exit 1
      cp "$SETTINGS" "$BAK_FILE" || exit 1
      out="$(jq -n --argjson sl "$SAVED" '{settingsExisted: true, statusLine: $sl}')" || exit 1
      printf '%s\n' "$out" > "$PREV_FILE" || exit 1
      out="$(jq --arg cmd "$CMD_STRING" '.statusLine = {type: "command", command: $cmd}' "$SETTINGS")" || exit 1
      write_settings "$out"
    else
      out="$(jq -n '{settingsExisted: false, statusLine: null}')" || exit 1
      printf '%s\n' "$out" > "$PREV_FILE" || exit 1
      out="$(jq -n --arg cmd "$CMD_STRING" '{statusLine: {type: "command", command: $cmd}}')" || exit 1
      write_settings "$out"
    fi
    echo "statusline.sh: mission statusline enabled — previous statusLine saved to $PREV_FILE"
    echo "statusline.sh: it appears on your next interaction in a Claude Code session"
    ;;

  disable)
    if [ ! -f "$PREV_FILE" ]; then
      echo "statusline.sh: not enabled (no $PREV_FILE) — nothing to restore" >&2
      exit 1
    fi
    EXISTED="$(jq -r '.settingsExisted' "$PREV_FILE" 2>/dev/null || echo "")"
    SAVED="$(jq '.statusLine // null' "$PREV_FILE" 2>/dev/null || echo null)"
    if [ "$EXISTED" = "true" ] && [ -f "$BAK_FILE" ] && [ -f "$SETTINGS" ] \
       && [ "$(jq -S 'del(.statusLine)' "$SETTINGS" 2>/dev/null)" = "$(jq -S 'del(.statusLine)' "$BAK_FILE" 2>/dev/null)" ]; then
      # No other key changed since enable → restore the original bytes exactly.
      cp "$BAK_FILE" "$SETTINGS" || exit 1
    elif [ -f "$SETTINGS" ]; then
      # Other keys changed since enable (e.g. another tool rewrote the file):
      # restore ONLY the statusLine key, leave everything else as-is.
      if [ "$SAVED" = "null" ]; then
        out="$(jq 'del(.statusLine)' "$SETTINGS")" || exit 1
      else
        out="$(jq --argjson sl "$SAVED" '.statusLine = $sl' "$SETTINGS")" || exit 1
      fi
      if [ "$EXISTED" = "false" ] && [ "$(printf '%s' "$out" | jq -cS .)" = "{}" ]; then
        # We created settings.json at enable time and nothing else was added.
        rm -f "$SETTINGS"
      else
        write_settings "$out"
      fi
    fi
    rm -f "$PREV_FILE" "$BAK_FILE"
    echo "statusline.sh: mission statusline disabled — settings.json restored"
    ;;

  status)
    if [ -f "$PREV_FILE" ]; then
      cur="$(jq -r '.statusLine.command // empty' "$SETTINGS" 2>/dev/null || true)"
      if [ "$cur" = "$CMD_STRING" ]; then
        echo "statusline: ENABLED (settings.json statusLine → $CMD_STRING)"
      else
        echo "statusline: enable marker present, but settings.json statusLine is '${cur:-<absent>}'"
        echo "  another tool may have rewritten settings.json — run './statusline.sh disable' then 'enable' to re-wire it"
      fi
    else
      echo "statusline: disabled"
    fi
    if m="$(find_mission)"; then
      echo "mission: detected at $m"
    else
      echo "mission: none detected from $PWD"
    fi
    ;;

  *)
    usage
    ;;
esac
exit 0
