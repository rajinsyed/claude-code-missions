#!/bin/bash
# tests/test-xar.sh — validates cross-area consistency — assertions
# XAR-01 (README) and XAR-02 (toy-mission fixture). XAR-03 lives in
# tests/test-consistency.sh.
set -u

KIT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
README="$KIT_ROOT/README.md"
TOY="$KIT_ROOT/toy-mission"
TOY_MISSION="$TOY/mission"
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

# ---------------------------------------------------------------------------
# XAR-01: README documents install/uninstall and the three known gaps vs
#         Factory (architecture §11).
# ---------------------------------------------------------------------------
xar01=0
if [ ! -s "$README" ]; then
  note "XAR-01: README.md missing or empty"
  xar01=1
else
  # (1) Install instructions referencing install.sh + the manifest.
  if ! grep -q 'install\.sh' "$README"; then
    note "XAR-01: README lacks install instructions referencing install.sh"
    xar01=1
  fi
  if ! grep -q 'mission-kit-manifest\.txt' "$README"; then
    note "XAR-01: README lacks a reference to the manifest (mission-kit-manifest.txt)"
    xar01=1
  fi
  # (2) Uninstall instructions referencing uninstall.sh.
  if ! grep -q 'uninstall\.sh' "$README"; then
    note "XAR-01: README lacks uninstall instructions referencing uninstall.sh"
    xar01=1
  fi
  # (3) Known-gaps section covering all three architecture §11 gaps.
  #     Extract the section body (from its heading to the next same-or-higher
  #     heading) so the gap greps are anchored to the section, not README-wide.
  gaps="$(awk 'f && /^##?[[:space:]]/ { exit } f { print } tolower($0) ~ /^##?[[:space:]].*known gaps/ { f = 1 }' "$README")"
  if [ -z "$gaps" ]; then
    note "XAR-01: README lacks a Known Gaps section (or it is empty)"
    xar01=1
  fi
  # Gap 1: handoff arbitration model-enforced, not platform-blocked.
  if ! printf '%s\n' "$gaps" | grep -qi 'model-enforced' \
     || ! printf '%s\n' "$gaps" | grep -qi 'platform'; then
    note "XAR-01: README Known Gaps section missing gap 1 (handoff arbitration model-enforced, not platform-blocked)"
    xar01=1
  fi
  # Gap 2: instructional orchestrator separation; claude --agent noted as advanced option.
  if ! printf '%s\n' "$gaps" | grep -qi 'instructional' \
     || ! printf '%s\n' "$gaps" | grep -q -- '--agent'; then
    note "XAR-01: README Known Gaps section missing gap 2 (instructional orchestrator separation; claude --agent advanced option)"
    xar01=1
  fi
  # Gap 3: no runner UI; progress_log.jsonl + /goal status are the observability surface.
  if ! printf '%s\n' "$gaps" | grep -q 'progress_log\.jsonl' \
     || ! printf '%s\n' "$gaps" | grep -q '/goal' \
     || ! printf '%s\n' "$gaps" | grep -qi 'no runner UI'; then
    note "XAR-01: README Known Gaps section missing gap 3 (no runner UI; progress_log.jsonl + /goal status)"
    xar01=1
  fi
fi
result XAR-01 "$xar01"

# ---------------------------------------------------------------------------
# XAR-02: Toy-mission fixture is a complete, schema-valid pre-authored
#         mission dir.
# ---------------------------------------------------------------------------
xar02=0

# toy-mission/README.md with execution instructions + assertion map.
if [ ! -s "$TOY/README.md" ]; then
  note "XAR-02: toy-mission/README.md missing or empty"
  xar02=1
fi

# Architecture §4 file set (per contract: those applicable to a pre-authored fixture).
for f in mission.md architecture.md features.json validation-contract.md \
         validation-state.json AGENTS.md services.yaml triage-log.md; do
  if [ ! -s "$TOY_MISSION/$f" ]; then
    note "XAR-02: toy-mission/mission/$f missing or empty"
    xar02=1
  fi
done
if [ ! -d "$TOY_MISSION/library" ]; then
  note "XAR-02: toy-mission/mission/library/ missing"
  xar02=1
fi

# features.json validates against kit/templates/features.schema.json
# (jq required-key/type/enum checks derived from the schema, architecture §5).
if ! jq empty "$TOY_MISSION/features.json" >/dev/null 2>&1; then
  note "XAR-02: toy-mission features.json not valid JSON"
  xar02=1
else
  if ! jq -e '
      .features
      | (type == "array") and (length > 0)
      and all(.[];
          has("id") and has("description") and has("kind") and has("milestone")
          and has("fulfills") and has("preconditions") and has("status")
          and has("attempts") and has("handoffs") and has("fixes")
          and (.id | type == "string")
          and (.description | type == "string")
          and (.milestone | type == "string")
          and (.fulfills | type == "array")
          and (.preconditions | type == "array")
          and (.handoffs | type == "array")
          and ((.fixes == null) or (.fixes | type == "string"))
          and (.kind as $k | ["implementation","scrutiny","flow-validation","fix"] | index($k) != null)
          and (.status as $s | ["pending","in_progress","completed","passed","blocked"] | index($s) != null)
        )
    ' "$TOY_MISSION/features.json" >/dev/null 2>&1; then
    note "XAR-02: toy-mission features.json entries fail the features.schema.json field/type/enum checks"
    xar02=1
  fi
  # Exactly 3 implementation + 1 scrutiny + 1 flow-validation, all pending, attempts 0.
  if ! jq -e '
      ([.features[] | select(.kind == "implementation")] | length == 3)
      and ([.features[] | select(.kind == "scrutiny")] | length == 1)
      and ([.features[] | select(.kind == "flow-validation")] | length == 1)
      and (.features | length == 5)
      and all(.features[]; .status == "pending" and .attempts == 0)
    ' "$TOY_MISSION/features.json" >/dev/null 2>&1; then
    note "XAR-02: toy-mission features.json is not exactly 3 implementation + 1 scrutiny + 1 flow-validation, all pending with attempts 0"
    xar02=1
  fi
fi

# validation-state.json lists every TOY-* assertion from the contract as "pending".
if ! jq empty "$TOY_MISSION/validation-state.json" >/dev/null 2>&1; then
  note "XAR-02: toy-mission validation-state.json not valid JSON"
  xar02=1
else
  toy_ids="$(sed -n 's/^### \(TOY-[0-9][0-9]*\):.*/\1/p' "$TOY_MISSION/validation-contract.md" 2>/dev/null | sort -u)"
  if [ -z "$toy_ids" ]; then
    note "XAR-02: no TOY-* assertion headings found in toy-mission validation-contract.md"
    xar02=1
  fi
  for id in $toy_ids; do
    if ! jq -e --arg id "$id" '.[$id] == "pending"' "$TOY_MISSION/validation-state.json" >/dev/null 2>&1; then
      note "XAR-02: validation-state.json does not list $id as \"pending\""
      xar02=1
    fi
  done
fi

# Every fixture fulfills ID exists in the fixture contract (reusable checker).
if ! bash "$KIT_ROOT/tests/test-consistency.sh" "$TOY_MISSION" >/dev/null 2>&1; then
  note "XAR-02: fixture fulfills references do not all resolve to contract assertion IDs"
  xar02=1
fi

result XAR-02 "$xar02"

exit $STATUS
