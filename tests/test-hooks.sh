#!/bin/bash
# tests/test-hooks.sh — validates kit/agents/mission/hooks/ — assertions HKS-01..HKS-05.
set -u

KIT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOKS="$KIT_ROOT/kit/agents/mission/hooks"
GUARD="$HOOKS/guard-mission-state.sh"
REQUIRE="$HOOKS/require-handoff.sh"
STATUS=0

note() { echo "  $*" >&2; }

result() {
  # result <ID> <0|nonzero>
  if [ "$2" -eq 0 ]; then
    echo "PASS $1"
  else
    echo "FAIL $1"
    STATUS=1
  fi
}

# Synthetic PreToolUse JSON payload for guard-mission-state.sh
pretooluse_json() {
  # pretooluse_json <tool_name> <file_path>
  jq -cn --arg tool "$1" --arg fp "$2" \
    '{tool_name: $tool, tool_input: {file_path: $fp}, cwd: "/tmp/anyrepo", transcript_path: "/tmp/transcript.jsonl", session_id: "test-session"}'
}

# Synthetic Stop-hook JSON payload for require-handoff.sh
stop_json() {
  # stop_json <cwd>
  jq -cn --arg cwd "$1" \
    '{cwd: $cwd, transcript_path: "/tmp/transcript.jsonl", stop_hook_active: false}'
}

# ---------------------------------------------------------------------------
# HKS-01: guard-mission-state.sh blocks Write/Edit targeting mission state
#         files with exit 2 and a non-empty stderr reason.
# ---------------------------------------------------------------------------
hks01=0
if [ ! -f "$GUARD" ]; then
  note "HKS-01: $GUARD does not exist"
  hks01=1
else
  for case in "Write /tmp/anyrepo/mission/features.json" \
              "Edit /tmp/anyrepo/mission/validation-state.json"; do
    tool="${case%% *}"
    fp="${case#* }"
    err="$(pretooluse_json "$tool" "$fp" | bash "$GUARD" 2>&1 >/dev/null)"
    rc=$?
    if [ "$rc" -ne 2 ]; then
      note "HKS-01: $tool $fp exited $rc (expected 2)"
      hks01=1
    fi
    if [ -z "$err" ]; then
      note "HKS-01: $tool $fp produced no stderr reason"
      hks01=1
    fi
  done
fi
result HKS-01 "$hks01"

# ---------------------------------------------------------------------------
# HKS-02: guard-mission-state.sh allows non-protected paths and tolerates
#         malformed input with exit 0.
# ---------------------------------------------------------------------------
hks02=0
if [ ! -f "$GUARD" ]; then
  note "HKS-02: $GUARD does not exist"
  hks02=1
else
  # (a) ordinary source file  (b) other mission file  (c) .bak of protected file
  for fp in "/tmp/anyrepo/src/app.ts" \
            "/tmp/anyrepo/mission/handoffs/2026-01-01T00-00-00Z__m1-f1.json" \
            "/tmp/anyrepo/mission/features.json.bak"; do
    pretooluse_json "Write" "$fp" | bash "$GUARD" >/dev/null 2>&1
    rc=$?
    if [ "$rc" -ne 0 ]; then
      note "HKS-02: path $fp exited $rc (expected 0)"
      hks02=1
    fi
  done
  # (d) empty stdin
  printf '' | bash "$GUARD" >/dev/null 2>&1
  rc=$?
  if [ "$rc" -ne 0 ]; then
    note "HKS-02: empty stdin exited $rc (expected 0)"
    hks02=1
  fi
  # (e) malformed JSON
  printf 'not-json' | bash "$GUARD" >/dev/null 2>&1
  rc=$?
  if [ "$rc" -ne 0 ]; then
    note "HKS-02: malformed JSON exited $rc (expected 0)"
    hks02=1
  fi
fi
result HKS-02 "$hks02"

# ---------------------------------------------------------------------------
# Helpers for require-handoff.sh tests.
# ---------------------------------------------------------------------------

# Writes a fully schema-valid handoff document to the given path.
write_valid_handoff() {
  # write_valid_handoff <path> <feature-id>
  jq -n --arg fid "$2" '{
    featureId: $fid,
    timestamp: "2026-01-01T00:00:00Z",
    successState: "success",
    commitId: "abc1234",
    handoff: {
      salientSummary: "Did the thing.",
      whatWasImplemented: "The thing.",
      whatWasLeftUndone: "",
      verification: { commandsRun: [], interactiveChecks: [] },
      discoveredIssues: [],
      skillFeedback: { followedProcedure: true, deviations: [], suggestedChanges: [] }
    }
  }' > "$1"
}

# ---------------------------------------------------------------------------
# HKS-03: require-handoff.sh exits 0 when no .current-feature breadcrumb
#         exists (non-mission contexts never obstructed).
# ---------------------------------------------------------------------------
hks03=0
if [ ! -f "$REQUIRE" ]; then
  note "HKS-03: $REQUIRE does not exist"
  hks03=1
else
  tmp3="$(mktemp -d)"
  mkdir -p "$tmp3/mission"   # mission/ exists but NO .current-feature, no handoffs/
  stop_json "$tmp3" | CLAUDE_PROJECT_DIR="$tmp3" bash "$REQUIRE" >/dev/null 2>&1
  rc=$?
  if [ "$rc" -ne 0 ]; then
    note "HKS-03: no-breadcrumb case exited $rc (expected 0)"
    hks03=1
  fi
  # Also with handoffs/ present — still exit 0 without a breadcrumb.
  mkdir -p "$tmp3/mission/handoffs"
  stop_json "$tmp3" | CLAUDE_PROJECT_DIR="$tmp3" bash "$REQUIRE" >/dev/null 2>&1
  rc=$?
  if [ "$rc" -ne 0 ]; then
    note "HKS-03: no-breadcrumb (handoffs/ present) exited $rc (expected 0)"
    hks03=1
  fi
  rm -rf "$tmp3"
fi
result HKS-03 "$hks03"

# ---------------------------------------------------------------------------
# HKS-04: require-handoff.sh exits 2 when breadcrumb exists but no fresh,
#         schema-valid handoff does. Three sub-cases:
#         (a) no matching handoff file at all
#         (b) matching handoff STALE (mtime older than breadcrumb via touch -t)
#         (c) fresh matching handoff missing required keys
#         All must exit 2 with stderr containing "handoff".
# ---------------------------------------------------------------------------
hks04=0
if [ ! -f "$REQUIRE" ]; then
  note "HKS-04: $REQUIRE does not exist"
  hks04=1
else
  FID="m1-f1-demo"

  # -- (a) breadcrumb, but handoffs/ has no file matching *__m1-f1-demo*.json
  tmp4a="$(mktemp -d)"
  mkdir -p "$tmp4a/mission/handoffs"
  printf '%s|%s' "$tmp4a/mission" "$FID" > "$tmp4a/mission/.current-feature"
  write_valid_handoff "$tmp4a/mission/handoffs/2026-01-01T00-00-00Z__other-feature.json" "other-feature"
  err="$(stop_json "$tmp4a" | CLAUDE_PROJECT_DIR="$tmp4a" bash "$REQUIRE" 2>&1 >/dev/null)"
  rc=$?
  if [ "$rc" -ne 2 ]; then
    note "HKS-04(a): missing-handoff case exited $rc (expected 2)"
    hks04=1
  fi
  case "$err" in
    *handoff*) : ;;
    *) note "HKS-04(a): stderr does not contain 'handoff': $err"; hks04=1 ;;
  esac
  rm -rf "$tmp4a"

  # -- (b) matching, schema-valid handoff but STALE (older than breadcrumb)
  tmp4b="$(mktemp -d)"
  mkdir -p "$tmp4b/mission/handoffs"
  printf '%s|%s' "$tmp4b/mission" "$FID" > "$tmp4b/mission/.current-feature"
  write_valid_handoff "$tmp4b/mission/handoffs/2026-01-01T00-00-00Z__${FID}.json" "$FID"
  # Force the handoff mtime into the past, well before the breadcrumb's.
  touch -t 202001010000 "$tmp4b/mission/handoffs/2026-01-01T00-00-00Z__${FID}.json"
  err="$(stop_json "$tmp4b" | CLAUDE_PROJECT_DIR="$tmp4b" bash "$REQUIRE" 2>&1 >/dev/null)"
  rc=$?
  if [ "$rc" -ne 2 ]; then
    note "HKS-04(b): stale-handoff case exited $rc (expected 2)"
    hks04=1
  fi
  case "$err" in
    *handoff*) : ;;
    *) note "HKS-04(b): stderr does not contain 'handoff': $err"; hks04=1 ;;
  esac
  rm -rf "$tmp4b"

  # -- (c) fresh matching handoff but missing required keys
  tmp4c="$(mktemp -d)"
  mkdir -p "$tmp4c/mission/handoffs"
  printf '%s|%s' "$tmp4c/mission" "$FID" > "$tmp4c/mission/.current-feature"
  sleep 1  # ensure handoff mtime is strictly newer than the breadcrumb's
  # Missing successState and handoff.verification.
  jq -n --arg fid "$FID" '{
    featureId: $fid,
    timestamp: "2026-01-01T00:00:00Z",
    commitId: "abc1234",
    handoff: {
      salientSummary: "Did the thing.",
      whatWasImplemented: "The thing.",
      whatWasLeftUndone: "",
      discoveredIssues: [],
      skillFeedback: { followedProcedure: true, deviations: [], suggestedChanges: [] }
    }
  }' > "$tmp4c/mission/handoffs/2026-01-01T00-00-01Z__${FID}.json"
  err="$(stop_json "$tmp4c" | CLAUDE_PROJECT_DIR="$tmp4c" bash "$REQUIRE" 2>&1 >/dev/null)"
  rc=$?
  if [ "$rc" -ne 2 ]; then
    note "HKS-04(c): missing-keys case exited $rc (expected 2)"
    hks04=1
  fi
  case "$err" in
    *handoff*) : ;;
    *) note "HKS-04(c): stderr does not contain 'handoff': $err"; hks04=1 ;;
  esac
  rm -rf "$tmp4c"
fi
result HKS-04 "$hks04"

# ---------------------------------------------------------------------------
# HKS-05: require-handoff.sh exits 0 for a fresh schema-valid handoff, with
#         no blocking message on stderr.
# ---------------------------------------------------------------------------
hks05=0
if [ ! -f "$REQUIRE" ]; then
  note "HKS-05: $REQUIRE does not exist"
  hks05=1
else
  FID="m1-f1-demo"
  tmp5="$(mktemp -d)"
  mkdir -p "$tmp5/mission/handoffs"
  printf '%s|%s' "$tmp5/mission" "$FID" > "$tmp5/mission/.current-feature"
  sleep 1  # handoff created strictly AFTER the breadcrumb
  write_valid_handoff "$tmp5/mission/handoffs/2026-01-01T00-00-02Z__${FID}.json" "$FID"
  err="$(stop_json "$tmp5" | CLAUDE_PROJECT_DIR="$tmp5" bash "$REQUIRE" 2>&1 >/dev/null)"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    note "HKS-05: valid-handoff case exited $rc (expected 0); stderr: $err"
    hks05=1
  fi
  if [ -n "$err" ]; then
    note "HKS-05: unexpected blocking message on stderr: $err"
    hks05=1
  fi
  rm -rf "$tmp5"
fi
result HKS-05 "$hks05"

exit $STATUS
