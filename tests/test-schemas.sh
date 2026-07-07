#!/bin/bash
# tests/test-schemas.sh — validates kit/templates/ — assertions TPL-01..TPL-04.
set -u

KIT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TPL="$KIT_ROOT/kit/templates"
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
# TPL-01: Template JSON files are valid JSON and handoff schema declares §6
#         required keys.
# ---------------------------------------------------------------------------
tpl01=0
for f in features.schema.json handoff.schema.json features.template.json validation-state.template.json; do
  if ! jq empty "$TPL/$f" >/dev/null 2>&1; then
    note "TPL-01: $TPL/$f missing or not valid JSON"
    tpl01=1
  fi
done
if [ "$tpl01" -eq 0 ]; then
  if ! jq -e '
      (.required // []) as $top
      | ((["featureId","timestamp","successState","commitId","handoff"] - $top) == [])
      and ((.properties.handoff.required // []) as $h
           | (["salientSummary","whatWasImplemented","whatWasLeftUndone","verification","discoveredIssues","skillFeedback"] - $h) == [])
    ' "$TPL/handoff.schema.json" >/dev/null 2>&1; then
    note "TPL-01: handoff.schema.json does not declare all §6 required keys (top-level and handoff object)"
    tpl01=1
  fi
fi
result TPL-01 "$tpl01"

# ---------------------------------------------------------------------------
# TPL-02: Every features.template.json entry carries every architecture §5
#         field with correct types and enum values.
# ---------------------------------------------------------------------------
tpl02=0
if ! jq -e '
    .features
    | (type == "array") and (length > 0)
    and all(.[];
        has("id") and has("description") and has("kind") and has("milestone")
        and has("fulfills") and has("preconditions") and has("status")
        and has("attempts") and has("handoffs") and has("fixes")
        and (.id | type == "string")
        and (.description | type == "string")
        and (.kind | type == "string")
        and (.milestone | type == "string")
        and (.fulfills | type == "array")
        and (.preconditions | type == "array")
        and (.status | type == "string")
        and (.attempts | type == "number")
        and (.handoffs | type == "array")
        and ((.fixes == null) or (.fixes | type == "string"))
        and (.kind as $k | ["implementation","scrutiny","flow-validation","fix"] | index($k) != null)
        and (.status as $s | ["pending","in_progress","completed","passed","blocked"] | index($s) != null)
      )
  ' "$TPL/features.template.json" >/dev/null 2>&1; then
  note "TPL-02: features.template.json entries missing §5 fields, or wrong types/enum values"
  tpl02=1
fi
result TPL-02 "$tpl02"

# ---------------------------------------------------------------------------
# TPL-03: features.template.json includes an example of every feature kind;
#         the fix example has a non-null string fixes naming an existing id.
# ---------------------------------------------------------------------------
tpl03=0
if ! jq -e '
    ([.features[].kind] | unique) as $kinds
    | (["fix","flow-validation","implementation","scrutiny"] - $kinds) == []
  ' "$TPL/features.template.json" >/dev/null 2>&1; then
  note "TPL-03: features.template.json does not include all four kinds"
  tpl03=1
fi
if ! jq -e '
    [.features[].id] as $ids
    | [.features[] | select(.kind == "fix")]
    | (length > 0)
    and all(.[]; (.fixes | type == "string") and (.fixes as $fx | $ids | index($fx) != null))
  ' "$TPL/features.template.json" >/dev/null 2>&1; then
  note "TPL-03: fix example missing, or its fixes field is not a string naming an original feature id"
  tpl03=1
fi
result TPL-03 "$tpl03"

# ---------------------------------------------------------------------------
# TPL-04: All Markdown/YAML templates exist, are non-empty, with expected
#         section headers.
# ---------------------------------------------------------------------------
tpl04=0
for f in mission.template.md architecture.template.md validation-contract.template.md AGENTS.template.md triage-log.template.md services.template.yaml; do
  if [ ! -s "$TPL/$f" ]; then
    note "TPL-04: $TPL/$f missing or empty"
    tpl04=1
  fi
done
for stem in mission architecture validation-contract AGENTS triage-log; do
  if ! grep -q '^# ' "$TPL/$stem.template.md" 2>/dev/null; then
    note "TPL-04: $stem.template.md lacks a '# ' title"
    tpl04=1
  fi
done
# Anchored: each keyword must appear as a bolded assertion field label
# ('- **Word**:'), not merely as a substring of some other word.
for word in Surface Priority Given When Then; do
  if ! grep -q "^- \*\*$word\*\*:" "$TPL/validation-contract.template.md" 2>/dev/null; then
    note "TPL-04: validation-contract.template.md lacks '- **$word**:' field line"
    tpl04=1
  fi
done
# Anchored: top-level YAML keys at column 0, not substrings inside comments.
for word in workingDirectory commands; do
  if ! grep -q "^$word:" "$TPL/services.template.yaml" 2>/dev/null; then
    note "TPL-04: services.template.yaml lacks top-level '$word:' key"
    tpl04=1
  fi
done
result TPL-04 "$tpl04"

exit $STATUS
