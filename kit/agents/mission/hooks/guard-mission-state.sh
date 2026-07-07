#!/bin/bash
# guard-mission-state.sh — PreToolUse hook (matcher Write|Edit) for mission agents.
# Blocks (exit 2) writes/edits targeting the orchestrator-owned mission state
# files mission/features.json and mission/validation-state.json. Allows (exit 0)
# everything else, including empty stdin or malformed JSON — this hook must
# never obstruct work outside the two protected files. Architecture §8.
set -u

INPUT="$(cat 2>/dev/null || true)"

# No input at all → allow.
[ -z "$INPUT" ] && exit 0

# Extract tool_input.file_path; tolerate malformed JSON or absent fields.
FILE_PATH="$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null || true)"

# No usable path → allow.
[ -z "$FILE_PATH" ] && exit 0

case "$FILE_PATH" in
  */mission/features.json)
    echo "BLOCKED: $FILE_PATH is orchestrator-owned mission state (mission/features.json). Workers must not modify it; report results in your handoff instead." >&2
    exit 2
    ;;
  */mission/validation-state.json)
    echo "BLOCKED: $FILE_PATH is orchestrator-owned mission state (mission/validation-state.json). Workers must not modify it; report results in your handoff instead." >&2
    exit 2
    ;;
esac

exit 0
