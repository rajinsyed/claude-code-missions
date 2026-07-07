#!/bin/bash
# require-handoff.sh — Stop hook (SubagentStop at runtime) for mission agents.
# Gates a worker's finish on a fresh, schema-valid handoff JSON. The
# orchestrator writes $CLAUDE_PROJECT_DIR/mission/.current-feature
# ("<MISSION_DIR>|<FEATURE_ID>") before spawning each worker; if that
# breadcrumb is absent this is not a mission context → exit 0 (never
# obstruct). If present, require at least one MISSION_DIR/handoffs/ file
# matching *__<FEATURE_ID>*.json that is strictly newer than the breadcrumb
# and jq-valid with the required keys from handoff.schema.json (§6).
# Missing/stale/invalid → exit 2. Architecture §8.
set -u

INPUT="$(cat 2>/dev/null || true)"

# Determine the project dir: $CLAUDE_PROJECT_DIR, else cwd from hook JSON.
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-}"
if [ -z "$PROJECT_DIR" ] && [ -n "$INPUT" ]; then
  PROJECT_DIR="$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)"
fi

# No project dir at all → not a mission context; never obstruct.
[ -z "$PROJECT_DIR" ] && exit 0

BREADCRUMB="$PROJECT_DIR/mission/.current-feature"

# No breadcrumb → not a mission worker run; never obstruct.
[ -f "$BREADCRUMB" ] || exit 0

LINE="$(head -n 1 "$BREADCRUMB" 2>/dev/null || true)"
MISSION_DIR="${LINE%%|*}"
FEATURE_ID="${LINE#*|}"

# Malformed breadcrumb (no '|' separator or empty parts) → never obstruct.
if [ -z "$MISSION_DIR" ] || [ -z "$FEATURE_ID" ] || [ "$MISSION_DIR" = "$LINE" ]; then
  exit 0
fi

block() {
  echo "BLOCKED: no fresh, valid handoff found for feature '$FEATURE_ID'. You must write your handoff JSON before finishing: create $MISSION_DIR/handoffs/<ISO-ts>__${FEATURE_ID}__<session-id>.json with the required keys (featureId, timestamp, successState, commitId, handoff{salientSummary, whatWasImplemented, whatWasLeftUndone, verification{commandsRun, interactiveChecks}, discoveredIssues, skillFeedback}), then finish." >&2
  exit 2
}

# jq filter asserting the required keys per handoff.schema.json (§6).
JQ_VALID='
  has("featureId") and has("timestamp") and has("successState")
  and has("commitId") and has("handoff")
  and ((.handoff? // null) | type == "object")
  and ((.handoff.salientSummary? // null) | (type == "string" and length > 0))
  and (.handoff | has("whatWasImplemented") and has("whatWasLeftUndone"))
  and ((.handoff.verification?.commandsRun? // null) | type == "array")
  and ((.handoff.verification?.interactiveChecks? // null) | type == "array")
  and ((.handoff.discoveredIssues? // null) | type == "array")
  and ((.handoff.skillFeedback? // null) | type == "object")
'

for f in "$MISSION_DIR/handoffs/"*"__${FEATURE_ID}"*.json; do
  [ -e "$f" ] || continue                      # glob matched nothing
  [ "$f" -nt "$BREADCRUMB" ] || continue       # must be strictly newer than the breadcrumb
  if jq -e "$JQ_VALID" "$f" >/dev/null 2>&1; then
    exit 0                                     # fresh, schema-valid handoff found
  fi
done

block
