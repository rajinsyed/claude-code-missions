#!/bin/bash
# tests/test-statusline.sh — validates the opt-in mission statusline,
# assertions STL-01..STL-04.
#
# CRITICAL SAFETY: like the installer tests, every case that touches
# settings.json runs against a sandboxed fake home created with mktemp -d.
# HOME is exported to the sandbox and asserted to be inside the mktemp area
# (and NOT inside the real home) BEFORE any step. The real ~/.claude is
# NEVER touched by this script.
set -u

KIT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SL_SCRIPT="$KIT_ROOT/kit/agents/mission/statusline/mission-statusline.sh"
SL_MANAGER="$KIT_ROOT/statusline.sh"
STATUS=0
REAL_HOME="$HOME"

WORK="$(mktemp -d)"
TMP_BASE="$(dirname "$WORK")"
SANDBOXES="$WORK"

note() { echo "  $*" >&2; }

result() {
  if [ "$2" -eq 0 ]; then
    echo "PASS $1"
  else
    echo "FAIL $1"
    STATUS=1
  fi
}

new_sandbox() {
  SANDBOX="$(mktemp -d)"
  case "$SANDBOX" in
    "$TMP_BASE"/*) : ;;
    *)
      echo "FATAL: sandbox $SANDBOX is not inside mktemp area $TMP_BASE — refusing" >&2
      exit 1
      ;;
  esac
  case "$SANDBOX" in
    "$REAL_HOME"|"$REAL_HOME"/*)
      echo "FATAL: sandbox $SANDBOX is inside the real home $REAL_HOME — refusing" >&2
      exit 1
      ;;
  esac
  export HOME="$SANDBOX"
  if [ "$HOME" = "$REAL_HOME" ]; then
    echo "FATAL: HOME still resolves to the real home $REAL_HOME — refusing" >&2
    exit 1
  fi
  SANDBOXES="$SANDBOXES $SANDBOX"
}

cleanup() {
  export HOME="$REAL_HOME"
  for d in $SANDBOXES; do
    case "$d" in
      "$TMP_BASE"/*) rm -rf "$d" ;;
    esac
  done
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# STL-01: both scripts exist, are executable, and parse cleanly
# ---------------------------------------------------------------------------
stl01=0
for s in "$SL_SCRIPT" "$SL_MANAGER"; do
  if [ ! -f "$s" ]; then
    note "STL-01: missing script: $s"
    stl01=1
    continue
  fi
  if [ ! -x "$s" ]; then
    note "STL-01: not executable: $s"
    stl01=1
  fi
  if ! bash -n "$s" 2>/dev/null; then
    note "STL-01: bash -n failed for $s"
    stl01=1
  fi
done
result STL-01 "$stl01"

# ---------------------------------------------------------------------------
# STL-02: no mission in cwd → passthrough/default, never errors
# ---------------------------------------------------------------------------
new_sandbox
stl02=0

PLAIN_DIR="$SANDBOX/plain-project"
mkdir -p "$PLAIN_DIR"

# (a) valid stdin, no mission, no prev-file → default "<basename> · <model>"
out="$(printf '{"workspace":{"current_dir":"%s"},"model":{"display_name":"Opus"},"session_id":"s1"}' "$PLAIN_DIR" | "$SL_SCRIPT")"
rc=$?
if [ "$rc" -ne 0 ] || [ -z "$out" ]; then
  note "STL-02: default case errored (rc=$rc) or printed nothing"
  stl02=1
fi
case "$out" in
  *plain-project*Opus*) : ;;
  *) note "STL-02: default line missing dir basename/model: '$out'"; stl02=1 ;;
esac

# (b) empty stdin → still exits 0 and prints something
out="$(printf '' | "$SL_SCRIPT")"
rc=$?
if [ "$rc" -ne 0 ] || [ -z "$out" ]; then
  note "STL-02: empty stdin errored (rc=$rc) or printed nothing ('$out')"
  stl02=1
fi

# (c) malformed stdin → still exits 0 and prints something
out="$(printf 'not json at all' | "$SL_SCRIPT")"
rc=$?
if [ "$rc" -ne 0 ] || [ -z "$out" ]; then
  note "STL-02: malformed stdin errored (rc=$rc) or printed nothing"
  stl02=1
fi

# (d) prev-file with a saved command → passthrough runs it with stdin piped
mkdir -p "$HOME/.claude"
printf '{"settingsExisted": true, "statusLine": {"type": "command", "command": "jq -r .model.display_name"}}\n' \
  > "$HOME/.claude/mission-kit-statusline-prev.json"
out="$(printf '{"workspace":{"current_dir":"%s"},"model":{"display_name":"PassedThrough"}}' "$PLAIN_DIR" | "$SL_SCRIPT")"
if [ "$out" != "PassedThrough" ]; then
  note "STL-02: passthrough did not exec the saved command with original stdin (got '$out')"
  stl02=1
fi
result STL-02 "$stl02"

# ---------------------------------------------------------------------------
# STL-03: mission fixture → counts, bar, running feature id, retry, fix queue
# ---------------------------------------------------------------------------
new_sandbox
stl03=0

REPO="$SANDBOX/proj"
MDIR="$REPO/mission"
mkdir -p "$MDIR" "$REPO/src/nested"
cat > "$MDIR/features.json" <<'EOF'
{
  "features": [
    {"id": "m1-f1", "kind": "implementation", "status": "passed",      "attempts": 1},
    {"id": "m1-f2", "kind": "implementation", "status": "passed",      "attempts": 1},
    {"id": "m1-f3-readme-edges", "kind": "implementation", "status": "in_progress", "attempts": 2},
    {"id": "m1-fix1", "kind": "fix", "status": "pending", "attempts": 0}
  ]
}
EOF
printf '%s|m1-f3-readme-edges\n' "$MDIR" > "$MDIR/.current-feature"

# cwd nested below the repo root → the walk-up must still find mission/.
out="$(printf '{"workspace":{"current_dir":"%s"},"model":{"display_name":"Opus"}}' "$REPO/src/nested" | "$SL_SCRIPT")"
rc=$?
if [ "$rc" -ne 0 ] || [ -z "$out" ]; then
  note "STL-03: mission case errored (rc=$rc) or printed nothing"
  stl03=1
fi
for frag in "2/4" "▓" "m1-f3-readme-edges" "retry 2/3" "1 fix queued"; do
  case "$out" in
    *"$frag"*) : ;;
    *) note "STL-03: output missing '$frag': '$out'"; stl03=1 ;;
  esac
done

# Two-row contract: the user's normal statusline renders FIRST, the mission
# row on its own line BELOW it.
mkdir -p "$HOME/.claude"
printf '{"settingsExisted": true, "statusLine": {"type": "command", "command": "echo BASELINE"}}\n' \
  > "$HOME/.claude/mission-kit-statusline-prev.json"
out="$(printf '{"workspace":{"current_dir":"%s"},"model":{"display_name":"Opus"}}' "$REPO/src/nested" | "$SL_SCRIPT")"
first="$(printf '%s\n' "$out" | head -n 1)"
last="$(printf '%s\n' "$out" | tail -n 1)"
if [ "$first" != "BASELINE" ]; then
  note "STL-03: first row is not the passthrough statusline (got '$first')"
  stl03=1
fi
case "$last" in
  *"▣"*"m1-f3-readme-edges"*) : ;;
  *) note "STL-03: last row is not the mission row (got '$last')"; stl03=1 ;;
esac

# all passed → mission complete
cat > "$MDIR/features.json" <<'EOF'
{"features": [
  {"id": "m1-f1", "kind": "implementation", "status": "passed", "attempts": 1},
  {"id": "m1-f2", "kind": "implementation", "status": "passed", "attempts": 1}
]}
EOF
rm -f "$MDIR/.current-feature"
out="$(printf '{"workspace":{"current_dir":"%s"}}' "$REPO" | "$SL_SCRIPT")"
case "$out" in
  *"mission complete"*) : ;;
  *) note "STL-03: all-passed output missing 'mission complete': '$out'"; stl03=1 ;;
esac

# truncated/partial features.json (mission mid-write) → no crash, prints line
printf '{"features": [{"id": "m1-f1", ' > "$MDIR/features.json"
out="$(printf '{"workspace":{"current_dir":"%s"},"model":{"display_name":"Opus"}}' "$REPO" | "$SL_SCRIPT")"
rc=$?
if [ "$rc" -ne 0 ] || [ -z "$out" ]; then
  note "STL-03: partial features.json crashed the bar (rc=$rc, out='$out')"
  stl03=1
fi
result STL-03 "$stl03"

# ---------------------------------------------------------------------------
# STL-04: enable/disable round-trip preserves settings.json exactly
# ---------------------------------------------------------------------------
new_sandbox
stl04=0

# Install the kit into the sandbox so the enable precondition (installed
# script) holds; the installer is already proven sandbox-safe by INS-01..10.
( cd "$KIT_ROOT" && ./install.sh ) > /dev/null 2>&1 || { note "STL-04: sandbox install failed"; stl04=1; }

SETTINGS="$HOME/.claude/settings.json"
PREV="$HOME/.claude/mission-kit-statusline-prev.json"
BAK="$HOME/.claude/mission-kit-statusline-prev-settings.bak"

# Decoy settings with OTHER keys and a pre-existing statusLine.
cat > "$SETTINGS" <<'EOF'
{
  "permissions": {"allow": ["Bash(ls:*)"], "defaultMode": "acceptEdits"},
  "env": {"FOO": "bar"},
  "statusLine": {"type": "command", "command": "echo original-bar"}
}
EOF
cp "$SETTINGS" "$WORK/settings.orig"

( cd "$KIT_ROOT" && ./statusline.sh enable ) > /dev/null 2> "$WORK/stl04-enable.err"
rc=$?
if [ "$rc" -ne 0 ]; then
  note "STL-04: enable exited $rc (stderr: $(cat "$WORK/stl04-enable.err"))"
  stl04=1
fi
cmd="$(jq -r '.statusLine.command // empty' "$SETTINGS" 2>/dev/null)"
if [ "$cmd" != "~/.claude/agents/mission/statusline/mission-statusline.sh" ]; then
  note "STL-04: statusLine.command not pointing at the kit script: '$cmd'"
  stl04=1
fi
if [ "$(jq -S 'del(.statusLine)' "$SETTINGS")" != "$(jq -S 'del(.statusLine)' "$WORK/settings.orig")" ]; then
  note "STL-04: enable changed keys other than statusLine"
  stl04=1
fi
if ! jq -e '.statusLine.command == "echo original-bar"' "$PREV" >/dev/null 2>&1; then
  note "STL-04: prev-file does not hold the original statusLine verbatim"
  stl04=1
fi

# Double-enable must be refused, leaving everything untouched.
cp "$SETTINGS" "$WORK/settings.enabled"
( cd "$KIT_ROOT" && ./statusline.sh enable ) > /dev/null 2>&1
if [ $? -eq 0 ]; then
  note "STL-04: double-enable was not refused"
  stl04=1
fi
if ! cmp -s "$SETTINGS" "$WORK/settings.enabled"; then
  note "STL-04: refused double-enable still modified settings.json"
  stl04=1
fi

# Disable → settings.json byte-identical to the original; aux files gone.
( cd "$KIT_ROOT" && ./statusline.sh disable ) > /dev/null 2> "$WORK/stl04-disable.err"
rc=$?
if [ "$rc" -ne 0 ]; then
  note "STL-04: disable exited $rc (stderr: $(cat "$WORK/stl04-disable.err"))"
  stl04=1
fi
if ! cmp -s "$SETTINGS" "$WORK/settings.orig"; then
  note "STL-04: settings.json not byte-identical to the original after disable"
  stl04=1
fi
if [ -e "$PREV" ] || [ -e "$BAK" ]; then
  note "STL-04: prev/bak files still present after disable"
  stl04=1
fi

# Disable without enable must fail cleanly.
( cd "$KIT_ROOT" && ./statusline.sh disable ) > /dev/null 2>&1
if [ $? -eq 0 ]; then
  note "STL-04: disable without enable exited 0"
  stl04=1
fi

# Pristine sub-case: no settings.json at all → enable creates it, disable
# removes it again (statusLine was the only key we ever wrote).
rm -f "$SETTINGS"
( cd "$KIT_ROOT" && ./statusline.sh enable ) > /dev/null 2>&1 || { note "STL-04: enable on missing settings.json failed"; stl04=1; }
if ! jq -e '.statusLine.type == "command"' "$SETTINGS" >/dev/null 2>&1; then
  note "STL-04: enable did not create settings.json with the statusLine"
  stl04=1
fi
( cd "$KIT_ROOT" && ./statusline.sh disable ) > /dev/null 2>&1 || { note "STL-04: disable after pristine enable failed"; stl04=1; }
if [ -e "$SETTINGS" ]; then
  note "STL-04: settings.json left behind after pristine enable/disable round-trip"
  stl04=1
fi

# Uninstall-while-enabled: uninstall.sh must run the disable path first.
cp "$WORK/settings.orig" "$SETTINGS"
( cd "$KIT_ROOT" && ./statusline.sh enable ) > /dev/null 2>&1 || { note "STL-04: re-enable before uninstall failed"; stl04=1; }
( cd "$KIT_ROOT" && ./uninstall.sh ) > /dev/null 2>&1 || { note "STL-04: uninstall while enabled failed"; stl04=1; }
if ! cmp -s "$SETTINGS" "$WORK/settings.orig"; then
  note "STL-04: uninstall did not restore the pre-enable settings.json"
  stl04=1
fi
if [ -e "$PREV" ] || [ -e "$BAK" ]; then
  note "STL-04: prev/bak files survived uninstall"
  stl04=1
fi
result STL-04 "$stl04"

exit "$STATUS"
