#!/bin/bash
# tests/test-consistency.sh — XAR-03: reusable fulfills-vs-contract consistency checker.
#
# Two modes:
#   1. Reusable mode:  bash tests/test-consistency.sh <mission-dir>
#      Checks that every assertion ID referenced in <mission-dir>/features.json's
#      `fulfills` arrays resolves to an assertion heading in that dir's
#      validation-contract.md. Exit 0 = zero dangling references; non-zero otherwise.
#   2. Self-test mode (no args — how tests/run-all.sh invokes it):
#      Runs the reusable check against the toy-mission fixture (must pass) and
#      against a deliberately broken copy with a dangling ID (must fail).
set -u

KIT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

note() { echo "  $*" >&2; }

# check_mission_dir <mission-dir>
# Prints dangling IDs to stderr; returns 0 if none, 1 otherwise.
check_mission_dir() {
  dir="$1"
  features="$dir/features.json"
  contract="$dir/validation-contract.md"

  if [ ! -f "$features" ]; then
    echo "consistency: missing $features" >&2
    return 1
  fi
  if [ ! -f "$contract" ]; then
    echo "consistency: missing $contract" >&2
    return 1
  fi
  if ! jq empty "$features" >/dev/null 2>&1; then
    echo "consistency: $features is not valid JSON" >&2
    return 1
  fi

  # All fulfills references, deduped.
  refs="$(jq -r '.features[].fulfills[]' "$features" 2>/dev/null | sort -u)"

  # Assertion IDs parsed from the contract's '### <ID>: ...' headings.
  ids="$(sed -n 's/^### \([A-Z][A-Z0-9]*-[A-Za-z0-9-]*\):.*/\1/p' "$contract" | sort -u)"

  rc=0
  for ref in $refs; do
    found=1
    for id in $ids; do
      if [ "$ref" = "$id" ]; then
        found=0
        break
      fi
    done
    if [ "$found" -ne 0 ]; then
      echo "consistency: dangling fulfills reference '$ref' (no such assertion heading in $contract)" >&2
      rc=1
    fi
  done
  return $rc
}

# --- Reusable mode -----------------------------------------------------------
if [ "$#" -ge 1 ]; then
  if check_mission_dir "$1"; then
    echo "consistency: OK — every fulfills reference in $1 resolves"
    exit 0
  fi
  exit 1
fi

# --- Self-test mode (XAR-03) -------------------------------------------------
STATUS=0

result() {
  if [ "$2" -eq 0 ]; then
    echo "PASS $1"
  else
    echo "FAIL $1"
    STATUS=1
  fi
}

xar03=0
TOY="$KIT_ROOT/toy-mission/mission"

# Positive case: toy fixture has zero dangling references.
if ! check_mission_dir "$TOY"; then
  note "XAR-03: consistency check FAILED on the toy fixture (expected pass)"
  xar03=1
fi

# Negative case: broken copy with a dangling fulfills ID must fail.
if [ -d "$TOY" ] && [ -f "$TOY/features.json" ]; then
  BROKEN="$(mktemp -d)"
  cp -R "$TOY/." "$BROKEN/"
  jq '.features[0].fulfills += ["TOY-99"]' "$BROKEN/features.json" > "$BROKEN/features.json.tmp" \
    && mv "$BROKEN/features.json.tmp" "$BROKEN/features.json"
  if check_mission_dir "$BROKEN" 2>/dev/null; then
    note "XAR-03: consistency check PASSED on a deliberately broken fixture (expected failure)"
    xar03=1
  fi
  rm -rf "$BROKEN"
else
  note "XAR-03: toy fixture missing — cannot run negative test"
  xar03=1
fi

result XAR-03 "$xar03"
exit $STATUS
