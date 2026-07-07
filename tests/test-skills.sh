#!/bin/bash
# tests/test-skills.sh — validates kit/skills/ — assertions SKL-01..SKL-04.
set -u

KIT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SKILLS_DIR="$KIT_ROOT/kit/skills"
PLAN="$SKILLS_DIR/mission-plan/SKILL.md"
RUN="$SKILLS_DIR/mission-run/SKILL.md"
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

frontmatter() {
  # Prints the frontmatter block between the first two '---' lines of a file.
  awk 'NR==1 { if ($0 == "---") { fm = 1; next } else exit } fm { if ($0 == "---") exit; print }' "$1"
}

# ---------------------------------------------------------------------------
# SKL-01: Both skills exist with frontmatter (name matching the skill dir,
#         non-empty description) and the exact line
#         `disable-model-invocation: true`.
# ---------------------------------------------------------------------------
skl01=0
for f in "$PLAN" "$RUN"; do
  if [ ! -f "$f" ]; then
    note "SKL-01: missing $f"
    skl01=1
    continue
  fi
  fm="$(frontmatter "$f")"
  if [ -z "$fm" ]; then
    note "SKL-01: $f has empty/unparseable frontmatter"
    skl01=1
    continue
  fi
  stem="$(basename "$(dirname "$f")")"
  if ! printf '%s\n' "$fm" | grep -qE "^name:[[:space:]]*${stem}[[:space:]]*$"; then
    note "SKL-01: $f name: does not match skill dir $stem"
    skl01=1
  fi
  if ! printf '%s\n' "$fm" | grep -qE '^description:[[:space:]]*[^[:space:]]'; then
    note "SKL-01: $f missing non-empty description:"
    skl01=1
  fi
  if ! printf '%s\n' "$fm" | grep -qx 'disable-model-invocation: true'; then
    note "SKL-01: $f lacks exact line 'disable-model-invocation: true'"
    skl01=1
  fi
done
result SKL-01 "$skl01"

# ---------------------------------------------------------------------------
# SKL-02: mission-run skill sets the full /goal condition — all fragments
#         (passed-or-blocked proved with jq; scrutiny synthesis pass;
#         discoveredIssues triaged; milestone_sealed logged) and the exact
#         fixed string `or stop after 150 turns`.
# ---------------------------------------------------------------------------
skl02=0
if [ ! -f "$RUN" ]; then
  note "SKL-02: missing $RUN"
  skl02=1
else
  while IFS= read -r frag; do
    if ! grep -qF "$frag" "$RUN"; then
      note "SKL-02: mission-run/SKILL.md lacks goal fragment: $frag"
      skl02=1
    fi
  done <<'EOF'
All features in mission/features.json have status "passed" or "blocked" (prove with jq)
every milestone has a scrutiny synthesis with status pass
all discoveredIssues are triaged in triage-log.md or fix-features
progress_log.jsonl records milestone_sealed for every milestone
or stop after 150 turns
EOF
fi
result SKL-02 "$skl02"

# ---------------------------------------------------------------------------
# SKL-03: mission-run skill encodes (a) attempts reaching 3 => blocked,
#         (b) the .current-feature breadcrumb lifecycle (written before
#         spawning, deleted after handoff acceptance), (c) resume semantics
#         (in_progress with no fresh handoff => reset to pending).
# ---------------------------------------------------------------------------
skl03=0
if [ ! -f "$RUN" ]; then
  note "SKL-03: missing $RUN"
  skl03=1
else
  # (a) a line ties attempts + 3 + blocked together
  if ! grep -i 'attempts' "$RUN" | grep -i 'blocked' | grep -q '3'; then
    note "SKL-03: no attempts-reaches-3-becomes-blocked rule"
    skl03=1
  fi
  # (b) breadcrumb written before spawning ...
  if ! grep -F '.current-feature' "$RUN" | grep -qi 'write'; then
    note "SKL-03: no step WRITING mission/.current-feature"
    skl03=1
  fi
  # ... and deleted after handoff acceptance
  if ! grep -F '.current-feature' "$RUN" | grep -qiE 'delete|remove'; then
    note "SKL-03: no step DELETING mission/.current-feature"
    skl03=1
  fi
  # (c) resume rule: in_progress with no fresh handoff -> reset to pending.
  # Each fragment is independently anchored to its exact wording, and all
  # three must co-occur on the same resume-rule line.
  for frag in 'status is `in_progress`' 'no fresh handoff' 'reset its status to `pending`'; do
    if ! grep -qF "$frag" "$RUN"; then
      note "SKL-03: resume rule missing exact fragment: $frag"
      skl03=1
    fi
  done
  if ! grep -F 'status is `in_progress`' "$RUN" | grep -F 'no fresh handoff' \
       | grep -qF 'reset its status to `pending`'; then
    note "SKL-03: resume-rule fragments do not co-occur on one rule line (in_progress + no fresh handoff -> pending)"
    skl03=1
  fi
fi
result SKL-03 "$skl03"

# ---------------------------------------------------------------------------
# SKL-STATE-COMMIT (non-contract): mission-run skill commits mission state —
#         the exact command `git add mission/ && git commit -m
#         "chore(mission): state update"` appears (a) at spawn-time (a line
#         mentioning "before spawning" carries the command), (b) at loop-end
#         (a line mentioning "final action" carries the command), and (c) the
#         gitignored-mission/ case explicitly skips these commits.
# ---------------------------------------------------------------------------
sklsc=0
STATE_COMMIT_CMD='git add mission/ && git commit -m "chore(mission): state update"'
if [ ! -f "$RUN" ]; then
  note "SKL-STATE-COMMIT: missing $RUN"
  sklsc=1
else
  if ! grep -qF "$STATE_COMMIT_CMD" "$RUN"; then
    note "SKL-STATE-COMMIT: exact mission-state commit command not found"
    sklsc=1
  fi
  # (a) spawn-time: commit command on a line about "before spawning"
  if ! grep -i 'before spawning' "$RUN" | grep -qF "$STATE_COMMIT_CMD"; then
    note "SKL-STATE-COMMIT: no mission-state commit step at spawn-time (before spawning)"
    sklsc=1
  fi
  # (b) loop-end: commit command on a line about the "final action"
  if ! grep -i 'final action' "$RUN" | grep -qF "$STATE_COMMIT_CMD"; then
    note "SKL-STATE-COMMIT: no mission-state commit as the FINAL action before the goal loop ends"
    sklsc=1
  fi
  # (c) gitignored mission/ => commits skipped, anchored to the final-action
  #     line so the skip rule provably covers the loop-end commit too.
  if ! grep -i 'final action' "$RUN" | grep -i 'gitignored' | grep -qi 'skip'; then
    note "SKL-STATE-COMMIT: final-action line lacks the gitignored-mission/ skip rule"
    sklsc=1
  fi
fi
result SKL-STATE-COMMIT "$sklsc"

# ---------------------------------------------------------------------------
# SKL-04: mission-plan skill contains all 8 numbered phase headers
#         (understand -> architecture -> infrastructure -> credentials ->
#          testing strategy -> readiness -> milestones -> proposal/author)
#         and a scaffolding instruction referencing the fixed string
#         `kit/templates/`.
# ---------------------------------------------------------------------------
skl04=0
if [ ! -f "$PLAN" ]; then
  note "SKL-04: missing $PLAN"
  skl04=1
else
  # Exactly 8 numbered phase headings at their actual heading level (##),
  # no more, no fewer — sub-headings at other levels must not count.
  total="$(grep -cE '^##[[:space:]]+Phase [0-9]' "$PLAN")"
  if [ "$total" -ne 8 ]; then
    note "SKL-04: expected exactly 8 numbered '## Phase N' headings, found $total"
    skl04=1
  fi
  # Each of Phase 1..8 appears exactly once as a level-2 heading, with the expected topic keyword.
  n=1
  for kw in 'understand' 'architect' 'infrastructure' 'credential' 'test' 'readiness' 'milestone' 'author|proposal'; do
    c="$(grep -cE "^##[[:space:]]+Phase ${n}[^0-9]" "$PLAN")"
    if [ "$c" -ne 1 ]; then
      note "SKL-04: Phase $n heading appears $c times (expected exactly 1)"
      skl04=1
    elif ! grep -E "^##[[:space:]]+Phase ${n}[^0-9]" "$PLAN" | grep -qiE "$kw"; then
      note "SKL-04: Phase $n heading does not mention expected topic ($kw)"
      skl04=1
    fi
    n=$((n + 1))
  done
  # Scaffolding instruction references the fixed string kit/templates/
  if ! grep -qF 'kit/templates/' "$PLAN"; then
    note "SKL-04: no scaffolding reference to fixed string kit/templates/"
    skl04=1
  fi
fi
result SKL-04 "$skl04"

exit $STATUS
