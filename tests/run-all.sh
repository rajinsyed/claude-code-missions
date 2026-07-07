#!/bin/bash
# tests/run-all.sh — entry point for the kit test suite.
# Runs every tests/test-*.sh; exit 0 = all green. Any failing script fails the run.
set -u

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
OVERALL=0
RAN=0

for t in "$TESTS_DIR"/test-*.sh; do
  [ -e "$t" ] || continue
  RAN=$((RAN + 1))
  echo "=== $(basename "$t") ==="
  # Executable bits are part of the repo contract (mode 100755). Running via
  # 'bash "$t"' would mask a lost bit, so verify it explicitly per script.
  if [ ! -x "$t" ]; then
    echo "FAIL: $(basename "$t") is not executable — restore the bit with: chmod +x $t" >&2
    OVERALL=1
    continue
  fi
  "$t"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "FAIL: $(basename "$t") exited $rc" >&2
    OVERALL=1
  fi
done

if [ "$RAN" -eq 0 ]; then
  echo "FAIL: no tests/test-*.sh scripts found" >&2
  OVERALL=1
fi

if [ "$OVERALL" -eq 0 ]; then
  echo "ALL TESTS GREEN ($RAN script(s))"
else
  echo "TEST SUITE FAILED" >&2
fi
exit $OVERALL
