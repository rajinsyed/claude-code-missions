#!/bin/bash
# tests/test-e2e-artifacts.sh — mechanical verification of an end-to-end toy
# mission run, assertions E2E-01..E2E-08 (defined in this script).
#
# Usage: bash tests/test-e2e-artifacts.sh <scratch-repo-path>
#
# The scratch repo is the /tmp git repo you ran `claude -p "/mission-run"`
# in (toy-mission/mission copied to ./mission; see toy-mission/README.md).
# The E2E-* assertions have surface "e2e (claude -p toy run)", NOT
# "structural (tests/run-all.sh)": they are only checkable against a real
# recorded run, so this script SKIPs with exit 0 when invoked without a
# scratch repo path (as tests/run-all.sh does). Invoke it explicitly with
# the scratch repo path to verify a run; any FAIL then exits non-zero.
#
# Side effects (evidence collection, all under gitignored tmp/e2e/):
#   - takes the post-run scoped ~/.claude snapshot (E2E-08) if absent
#   - writes tmp/e2e/e2e-results.json (per-assertion status + observation)
#   - copies the scratch repo's mission/ into tmp/e2e/artifacts/
set -u

KIT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
E2E_DIR="$KIT_ROOT/tmp/e2e"
RUN_LOG="$E2E_DIR/run.log"
EXIT_CODE_FILE="$E2E_DIR/run-exit-code.txt"

STATUS=0
RESULTS_TMP="$(mktemp)"
trap 'rm -f "$RESULTS_TMP"' EXIT

note() { echo "  $*" >&2; }

# result <ID> <0|nonzero> <observation> — prints PASS/FAIL and records the
# outcome for the results JSON.
result() {
  _id="$1"; _rc="$2"; _obs="$3"
  if [ "$_rc" -eq 0 ]; then
    echo "PASS $_id"
    _st="pass"
  else
    echo "FAIL $_id"
    note "$_id: $_obs"
    STATUS=1
    _st="fail"
  fi
  jq -n --arg id "$_id" --arg st "$_st" --arg obs "$_obs" \
    '{id: $id, status: $st, observation: $obs}' >> "$RESULTS_TMP"
}

# --- Resolve the scratch repo -----------------------------------------------
SCRATCH="${1:-}"
if [ -z "$SCRATCH" ] || [ ! -d "$SCRATCH/mission" ]; then
  echo "SKIP E2E-01..E2E-08: e2e surface, not structural — record a toy run per" \
       "toy-mission/README.md and pass its scratch repo path as \$1"
  exit 0
fi
MISSION="$SCRATCH/mission"
echo "scratch repo: $SCRATCH"

# ---------------------------------------------------------------------------
# E2E-01: Toy run terminates autonomously with exit code 0
# ---------------------------------------------------------------------------
e01=0; e01_obs=""
if [ ! -s "$RUN_LOG" ]; then
  e01=1; e01_obs="run.log missing or empty at $RUN_LOG"
elif [ ! -s "$EXIT_CODE_FILE" ]; then
  e01=1; e01_obs="run exit code not recorded at $EXIT_CODE_FILE (run not finished?)"
else
  rc="$(head -n1 "$EXIT_CODE_FILE" | tr -d '[:space:]')"
  if [ "$rc" != "0" ]; then
    e01=1; e01_obs="claude -p exited $rc (expected 0)"
  elif tail -n 40 "$RUN_LOG" | grep -qiE 'API Error|credit balance|rate limit|fatal|Traceback'; then
    e01=1; e01_obs="run.log tail contains crash/API-error indicators"
  elif ! tail -n 60 "$RUN_LOG" | grep -qiE 'milestone|sealed|passed|goal|blocked'; then
    e01=1; e01_obs="run.log tail lacks any goal-loop conclusion indicator (milestone/sealed/passed/goal)"
  else
    e01_obs="exit code 0; run.log tail reports goal-loop conclusion, no crash indicators"
  fi
fi
result E2E-01 "$e01" "$e01_obs"

# ---------------------------------------------------------------------------
# E2E-02: All three implementation features reach terminal status "passed"
# ---------------------------------------------------------------------------
e02=0; e02_obs=""
FEATURES="$MISSION/features.json"
if [ ! -s "$FEATURES" ] || ! jq -e . "$FEATURES" > /dev/null 2>&1; then
  e02=1; e02_obs="mission/features.json missing or not valid JSON"
else
  impl_total="$(jq '[.features[] | select(.kind=="implementation")] | length' "$FEATURES")"
  impl_passed="$(jq '[.features[] | select(.kind=="implementation") | select(.status=="passed")] | length' "$FEATURES")"
  nonterminal="$(jq '[.features[] | select(.status=="pending" or .status=="in_progress" or .status=="completed")] | length' "$FEATURES")"
  bad_blocked="$(jq '[.features[] | select(.status=="blocked") | select(.attempts != 3 or ((.handoffs|length) < 3))] | length' "$FEATURES")"
  blocked_count="$(jq '[.features[] | select(.status=="blocked")] | length' "$FEATURES")"
  if [ "$impl_total" -ne 3 ]; then
    e02=1; e02_obs="expected 3 implementation features, found $impl_total"
  elif [ "$impl_passed" -ne 3 ]; then
    e02=1; e02_obs="only $impl_passed/3 implementation features have status passed: $(jq -c '[.features[] | select(.kind=="implementation") | {id, status}]' "$FEATURES")"
  elif [ "$nonterminal" -ne 0 ]; then
    e02=1; e02_obs="$nonterminal feature(s) left pending/in_progress/completed: $(jq -c '[.features[] | select(.status=="pending" or .status=="in_progress" or .status=="completed") | .id]' "$FEATURES")"
  elif [ "$bad_blocked" -ne 0 ]; then
    e02=1; e02_obs="blocked feature(s) without attempts==3 and >=3 handoffs"
  else
    e02_obs="all 3 implementation features passed; no pending/in_progress/completed; blocked=$blocked_count"
  fi
fi
result E2E-02 "$e02" "$e02_obs"

# ---------------------------------------------------------------------------
# E2E-03: One schema-valid handoff JSON exists per attempted feature
# ---------------------------------------------------------------------------
# newest_handoff <feature-id> — echoes newest mission/handoffs/*__<id>*.json
# (ISO timestamp prefixes sort lexically) or nothing.
newest_handoff() {
  ls -1 "$MISSION/handoffs/"*"__${1}"*.json 2>/dev/null | sort | tail -n 1
}

e03=0; e03_obs="every attempted feature has a newest schema-valid handoff with matching featureId"
if [ ! -s "$FEATURES" ]; then
  e03=1; e03_obs="features.json unavailable"
else
  attempted_ids="$(jq -r '.features[] | select(.attempts >= 1) | .id' "$FEATURES")"
  if [ -z "$attempted_ids" ]; then
    e03=1; e03_obs="no feature has attempts >= 1"
  fi
  for fid in $attempted_ids; do
    hf="$(newest_handoff "$fid")"
    if [ -z "$hf" ]; then
      e03=1; e03_obs="no handoff file matches *__${fid}*.json"
      continue
    fi
    if ! jq -e '
        (.featureId | type == "string") and
        (.timestamp | type == "string") and
        ([.successState] | inside(["success","partial","failure"])) and
        ((.commitId | type == "string") or (.commitId == null)) and
        (.handoff | type == "object") and
        (.handoff.salientSummary | type == "string" and length > 0) and
        (.handoff.whatWasImplemented | type == "string") and
        (.handoff.whatWasLeftUndone | type == "string") and
        (.handoff.verification | type == "object") and
        (.handoff.verification.commandsRun | type == "array") and
        (.handoff.verification.interactiveChecks | type == "array") and
        (.handoff.discoveredIssues | type == "array") and
        (.handoff.skillFeedback | type == "object")
      ' "$hf" > /dev/null 2>&1; then
      e03=1; e03_obs="newest handoff for $fid fails schema required-key checks: $hf"
      continue
    fi
    got_id="$(jq -r '.featureId' "$hf")"
    if [ "$got_id" != "$fid" ]; then
      e03=1; e03_obs="handoff $hf has featureId '$got_id', filename says '$fid'"
    fi
  done
fi
result E2E-03 "$e03" "$e03_obs"

# ---------------------------------------------------------------------------
# E2E-04: Scratch repo git history: >=1 commit per implementation feature
# ---------------------------------------------------------------------------
e04=0; e04_obs=""
root_commit="$(git -C "$SCRATCH" rev-list --max-parents=0 HEAD 2>/dev/null | head -n1)"
commit_list=""
if [ -z "$root_commit" ]; then
  e04=1; e04_obs="scratch repo has no git history"
else
  impl_ids="$(jq -r '.features[] | select(.kind=="implementation") | select(.status=="passed") | .id' "$FEATURES" 2>/dev/null)"
  for fid in $impl_ids; do
    hf="$(newest_handoff "$fid")"
    cid="$(jq -r '.commitId // empty' "$hf" 2>/dev/null)"
    if [ -z "$cid" ]; then
      e04=1; e04_obs="newest handoff for $fid has null/missing commitId"
      continue
    fi
    ctype="$(git -C "$SCRATCH" cat-file -t "$cid" 2>/dev/null)"
    if [ "$ctype" != "commit" ]; then
      e04=1; e04_obs="commitId $cid for $fid does not resolve to a commit (got '$ctype')"
      continue
    fi
    full="$(git -C "$SCRATCH" rev-parse "$cid" 2>/dev/null)"
    if [ "$full" = "$root_commit" ]; then
      e04=1; e04_obs="$fid's commitId is the initial scaffold commit"
      continue
    fi
    commit_list="$commit_list $full"
  done
  distinct="$(echo "$commit_list" | tr ' ' '\n' | sed '/^$/d' | sort -u | wc -l | tr -d ' ')"
  if [ "$e04" -eq 0 ] && [ "$distinct" -lt 3 ]; then
    e04=1; e04_obs="only $distinct distinct implementation commits (need >=3, excluding scaffold)"
  fi
  porcelain="$(git -C "$SCRATCH" status --porcelain)"
  if [ -n "$porcelain" ]; then
    e04=1; e04_obs="scratch repo git status not clean at end: $(echo "$porcelain" | head -n 5 | tr '\n' ';')"
  fi
  [ "$e04" -eq 0 ] && e04_obs="3 passed implementation features map to $distinct distinct real commits (scaffold excluded); git status clean"
fi
result E2E-04 "$e04" "$e04_obs"

# ---------------------------------------------------------------------------
# E2E-05: Scrutiny synthesis passing with one review per completed feature
# ---------------------------------------------------------------------------
e05=0; e05_obs=""
SYN="$MISSION/validation/1/scrutiny/synthesis.json"
REVIEWS_DIR="$MISSION/validation/1/scrutiny/reviews"
if [ ! -s "$SYN" ] || ! jq -e . "$SYN" > /dev/null 2>&1; then
  e05=1; e05_obs="synthesis.json missing or unparseable at $SYN"
else
  syn_status="$(jq -r '.status' "$SYN")"
  feat_outcomes="$(jq '(.features // {}) | length' "$SYN")"
  if [ "$syn_status" != "pass" ]; then
    e05=1; e05_obs="synthesis status is '$syn_status', expected 'pass'"
  elif [ "$feat_outcomes" -lt 3 ]; then
    e05=1; e05_obs="synthesis has $feat_outcomes per-feature outcomes, expected >=3"
  fi
  impl_ids="$(jq -r '.features[] | select(.kind=="implementation") | select(.status=="passed" or .status=="completed") | .id' "$FEATURES" 2>/dev/null)"
  impl_count="$(echo "$impl_ids" | sed '/^$/d' | wc -l | tr -d ' ')"
  review_count="$(ls -1 "$REVIEWS_DIR"/*.json 2>/dev/null | wc -l | tr -d ' ')"
  if [ "$review_count" != "$impl_count" ]; then
    e05=1; e05_obs="reviews/ has $review_count JSONs, expected exactly $impl_count (one per completed implementation feature)"
  fi
  for fid in $impl_ids; do
    rv="$REVIEWS_DIR/$fid.json"
    if [ ! -s "$rv" ]; then
      e05=1; e05_obs="missing review $rv"
      continue
    fi
    if ! jq -e '
        (.status == "pass" or .status == "fail") and
        (.issues | type == "array") and
        ([.issues[] | select((.severity == "blocking" or .severity == "non_blocking") | not)] | length == 0)
      ' "$rv" > /dev/null 2>&1; then
      e05=1; e05_obs="review $rv fails shape checks (status in pass|fail, issues[] severity in blocking|non_blocking)"
    fi
  done
  [ "$e05" -eq 0 ] && e05_obs="synthesis status pass with $feat_outcomes feature outcomes; exactly $review_count well-formed reviews (one per completed implementation feature)"
fi
result E2E-05 "$e05" "$e05_obs"

# ---------------------------------------------------------------------------
# E2E-06: Flow-validation report covers every TOY-* through the real CLI
# ---------------------------------------------------------------------------
e06=0; e06_obs=""
UT_DIR="$MISSION/validation/1/user-testing"
TOY_IDS="TOY-01 TOY-02 TOY-03 TOY-04 TOY-05 TOY-06 TOY-07 TOY-08"
report_count="$(ls -1 "$UT_DIR"/*.json 2>/dev/null | wc -l | tr -d ' ')"
if [ "$report_count" -lt 1 ]; then
  e06=1; e06_obs="no report JSON under $UT_DIR"
else
  ALL_IDS_TMP="$(mktemp)"
  for rpt in "$UT_DIR"/*.json; do
    if ! jq -e . "$rpt" > /dev/null 2>&1; then
      e06=1; e06_obs="report $rpt is not valid JSON"
      continue
    fi
    jq -r '.assertions[]?.id // empty' "$rpt" >> "$ALL_IDS_TMP"
    bad_status="$(jq '[.assertions[]? | select((.status == "pass" or .status == "fail" or .status == "blocked") | not)] | length' "$rpt")"
    if [ "$bad_status" -ne 0 ]; then
      e06=1; e06_obs="report $rpt has assertion status outside pass|fail|blocked"
    fi
    # Every asserted TOY entry must reference existing evidence under
    # mission/evidence/1/ (paths recorded relative to mission/ or repo root).
    ev_paths="$(jq -r '.assertions[]? | .evidence[]? // empty' "$rpt")"
    if [ -z "$ev_paths" ]; then
      e06=1; e06_obs="report $rpt has assertions with no evidence references"
    fi
    for ev in $ev_paths; do
      case "$ev" in
        *evidence/1/*) : ;;
        *) e06=1; e06_obs="evidence path '$ev' in $rpt is not under evidence/1/" ;;
      esac
      if [ ! -e "$MISSION/$ev" ] && [ ! -e "$SCRATCH/$ev" ] && [ ! -e "$ev" ]; then
        e06=1; e06_obs="evidence file '$ev' referenced by $rpt not found on disk"
      fi
    done
  done
  for toy in $TOY_IDS; do
    n="$(grep -c "^${toy}\$" "$ALL_IDS_TMP" || true)"
    if [ "$n" -ne 1 ]; then
      e06=1; e06_obs="$toy appears $n times across reports (expected exactly once)"
    fi
  done
  rm -f "$ALL_IDS_TMP"
  # Evidence must demonstrate the wordstats CLI was actually exercised.
  if ! grep -rq "wordstats" "$MISSION/evidence/1/" 2>/dev/null; then
    e06=1; e06_obs="mission/evidence/1/ does not mention wordstats — CLI exercise not evidenced"
  fi
  [ "$e06" -eq 0 ] && e06_obs="$report_count report(s); all 8 TOY-* IDs covered exactly once with valid statuses and on-disk evidence under mission/evidence/1/ showing wordstats CLI runs"
fi
result E2E-06 "$e06" "$e06_obs"

# ---------------------------------------------------------------------------
# E2E-07: Milestone 1 sealed — validation-state resolved, milestone_sealed logged
# ---------------------------------------------------------------------------
e07=0; e07_obs=""
VSTATE="$MISSION/validation-state.json"
PLOG="$MISSION/progress_log.jsonl"
if [ ! -s "$VSTATE" ] || ! jq -e . "$VSTATE" > /dev/null 2>&1; then
  e07=1; e07_obs="validation-state.json missing or unparseable"
else
  unresolved="$(jq '[to_entries[] | select(.key | startswith("TOY-")) | select((.value | type != "object") or ((.value.status == "passed" or .value.status == "failed") | not))] | length' "$VSTATE")"
  toy_count="$(jq '[to_entries[] | select(.key | startswith("TOY-"))] | length' "$VSTATE")"
  if [ "$toy_count" -ne 8 ]; then
    e07=1; e07_obs="expected 8 TOY-* keys in validation-state.json, found $toy_count"
  elif [ "$unresolved" -ne 0 ]; then
    e07=1; e07_obs="$unresolved TOY-* entrie(s) not resolved to {status: passed|failed}: $(jq -c . "$VSTATE")"
  fi
fi
if [ ! -s "$PLOG" ]; then
  e07=1; e07_obs="progress_log.jsonl missing or empty"
else
  sealed_line="$(grep -n 'milestone_sealed' "$PLOG" | tail -n 1)"
  if [ -z "$sealed_line" ]; then
    e07=1; e07_obs="no milestone_sealed line in progress_log.jsonl"
  else
    sealed_ln="${sealed_line%%:*}"
    sealed_json="${sealed_line#*:}"
    if ! echo "$sealed_json" | jq -e '(.type == "milestone_sealed") and ((.milestone|tostring) == "1") and (.timestamp | type == "string")' > /dev/null 2>&1; then
      e07=1; e07_obs="milestone_sealed line is not well-formed for milestone 1: $sealed_json"
    else
      scrutiny_ln="$(grep -n 'm1-scrutiny' "$PLOG" | grep -iE 'completed|passed' | tail -n 1 | cut -d: -f1)"
      flow_ln="$(grep -n 'm1-flow-validation' "$PLOG" | grep -iE 'completed|passed' | tail -n 1 | cut -d: -f1)"
      if [ -z "$scrutiny_ln" ] || [ -z "$flow_ln" ]; then
        e07=1; e07_obs="progress_log lacks completion lines for m1-scrutiny and/or m1-flow-validation"
      elif [ "$sealed_ln" -le "$scrutiny_ln" ] || [ "$sealed_ln" -le "$flow_ln" ]; then
        e07=1; e07_obs="milestone_sealed (line $sealed_ln) not ordered after scrutiny (line $scrutiny_ln) and flow-validation (line $flow_ln) completions"
      fi
    fi
  fi
fi
[ "$e07" -eq 0 ] && e07_obs="all 8 TOY-* resolved to passed/failed; well-formed milestone_sealed for milestone 1 ordered after scrutiny and flow-validation completions"
result E2E-07 "$e07" "$e07_obs"

# ---------------------------------------------------------------------------
# E2E-08: No stray state — breadcrumb removed, ~/.claude untouched (scoped)
# ---------------------------------------------------------------------------
e08=0; e08_obs=""
PRE_FILES="$E2E_DIR/snapshot-prerun-files.txt"
PRE_SUMS="$E2E_DIR/snapshot-prerun-shasums.txt"
PRE_CFG="$E2E_DIR/snapshot-prerun-checksums.txt"
POST_FILES="$E2E_DIR/snapshot-postrun-files.txt"
POST_SUMS="$E2E_DIR/snapshot-postrun-shasums.txt"
POST_CFG="$E2E_DIR/snapshot-postrun-checksums.txt"
if [ ! -s "$PRE_FILES" ] || [ ! -s "$PRE_SUMS" ] || [ ! -s "$PRE_CFG" ]; then
  e08=1; e08_obs="pre-run scoped snapshots missing under tmp/e2e/"
else
  # Take the post-run scoped snapshot now if the worker has not already.
  if [ ! -s "$POST_FILES" ]; then
    find "$HOME/.claude/agents" "$HOME/.claude/skills" -type f 2>/dev/null | sort > "$POST_FILES"
    find "$HOME/.claude/agents" "$HOME/.claude/skills" -type f 2>/dev/null | sort | xargs shasum > "$POST_SUMS"
    shasum "$HOME/.claude/settings.json" "$HOME/.claude/CLAUDE.md" > "$POST_CFG"
  fi
  if ! diff -q "$PRE_FILES" "$POST_FILES" > /dev/null 2>&1; then
    e08=1; e08_obs="scoped file list changed: $(diff "$PRE_FILES" "$POST_FILES" | head -n 5 | tr '\n' ';')"
  elif ! diff -q "$PRE_SUMS" "$POST_SUMS" > /dev/null 2>&1; then
    e08=1; e08_obs="scoped file contents changed: $(diff "$PRE_SUMS" "$POST_SUMS" | head -n 5 | tr '\n' ';')"
  elif ! diff -q "$PRE_CFG" "$POST_CFG" > /dev/null 2>&1; then
    e08=1; e08_obs="settings.json / CLAUDE.md checksums changed: $(diff "$PRE_CFG" "$POST_CFG" | tr '\n' ';')"
  fi
fi
if [ -e "$MISSION/.current-feature" ]; then
  e08=1; e08_obs="${e08_obs:+$e08_obs; }mission/.current-feature still exists (breadcrumb not cleaned up)"
fi
[ "$e08" -eq 0 ] && e08_obs="scoped ~/.claude snapshots byte-identical (agents+skills file list and shasums); settings.json/CLAUDE.md checksums unchanged; .current-feature absent"
result E2E-08 "$e08" "$e08_obs"

# --- Evidence collection ------------------------------------------------------
mkdir -p "$E2E_DIR"
jq -s '{results: ., overall: (if ([.[] | select(.status=="fail")] | length) == 0 then "pass" else "fail" end)}' \
  "$RESULTS_TMP" > "$E2E_DIR/e2e-results.json"
echo "results JSON: $E2E_DIR/e2e-results.json"

rm -rf "$E2E_DIR/artifacts"
mkdir -p "$E2E_DIR/artifacts"
cp -R "$MISSION" "$E2E_DIR/artifacts/mission"
echo "artifacts copied to: $E2E_DIR/artifacts/mission"

exit $STATUS
