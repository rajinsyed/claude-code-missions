#!/bin/bash
# tests/test-agents.sh — validates kit/agents/mission/*.md — assertions AGT-01..AGT-06.
set -u

KIT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AGENTS_DIR="$KIT_ROOT/kit/agents/mission"
WORKER="$AGENTS_DIR/mission-worker.md"
SCRUTINY="$AGENTS_DIR/mission-scrutiny.md"
REVIEWER="$AGENTS_DIR/mission-reviewer.md"
FLOW="$AGENTS_DIR/mission-flow-validator.md"
RUN_SKILL="$KIT_ROOT/kit/skills/mission-run/SKILL.md"
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
# AGT-01: All four mission agents exist with parseable frontmatter, name
#         matching the filename stem, non-empty description, no memory field.
# ---------------------------------------------------------------------------
agt01=0
for f in "$WORKER" "$SCRUTINY" "$REVIEWER" "$FLOW"; do
  if [ ! -f "$f" ]; then
    note "AGT-01: missing $f"
    agt01=1
    continue
  fi
  fm="$(frontmatter "$f")"
  if [ -z "$fm" ]; then
    note "AGT-01: $(basename "$f") has empty/unparseable frontmatter"
    agt01=1
    continue
  fi
  stem="$(basename "$f" .md)"
  if ! printf '%s\n' "$fm" | grep -qE "^name:[[:space:]]*${stem}[[:space:]]*$"; then
    note "AGT-01: $(basename "$f") name: does not match filename stem $stem"
    agt01=1
  fi
  if ! printf '%s\n' "$fm" | grep -qE "^description:[[:space:]]*[^[:space:]]"; then
    note "AGT-01: $(basename "$f") missing non-empty description:"
    agt01=1
  fi
  if printf '%s\n' "$fm" | grep -q "^memory:"; then
    note "AGT-01: $(basename "$f") declares a memory field (forbidden in v1)"
    agt01=1
  fi
done
result AGT-01 "$agt01"

# ---------------------------------------------------------------------------
# AGT-02: Every agent description carries the exact mission-only isolation
#         sentence (fixed-string match inside the frontmatter description).
# ---------------------------------------------------------------------------
SENTENCE="Only used within an explicit mission run started by /mission-run. Never delegate to this agent outside a mission."
agt02=0
for f in "$WORKER" "$SCRUTINY" "$REVIEWER" "$FLOW"; do
  if [ ! -f "$f" ]; then
    note "AGT-02: missing $f"
    agt02=1
    continue
  fi
  if ! frontmatter "$f" | grep '^description:' | grep -qF "$SENTENCE"; then
    note "AGT-02: $(basename "$f") description lacks the exact isolation sentence"
    agt02=1
  fi
done
result AGT-02 "$agt02"

# ---------------------------------------------------------------------------
# AGT-03: mission-worker declares numeric maxTurns and both frontmatter hooks
#         with ~/.claude install paths (not repo-relative paths).
# ---------------------------------------------------------------------------
agt03=0
if [ ! -f "$WORKER" ]; then
  note "AGT-03: missing $WORKER"
  agt03=1
else
  wfm="$(frontmatter "$WORKER")"
  if ! printf '%s\n' "$wfm" | grep -qE '^maxTurns:[[:space:]]*[0-9]+[[:space:]]*$'; then
    note "AGT-03: no numeric maxTurns: in mission-worker frontmatter"
    agt03=1
  fi
  if ! printf '%s\n' "$wfm" | grep -q 'PreToolUse'; then
    note "AGT-03: no PreToolUse hook entry"
    agt03=1
  fi
  if ! printf '%s\n' "$wfm" | grep -qF 'Write|Edit'; then
    note "AGT-03: no matcher Write|Edit"
    agt03=1
  fi
  if ! printf '%s\n' "$wfm" | grep -qF '~/.claude/agents/mission/hooks/guard-mission-state.sh'; then
    note "AGT-03: guard-mission-state.sh not referenced via ~/.claude install path"
    agt03=1
  fi
  if ! printf '%s\n' "$wfm" | grep -q 'Stop'; then
    note "AGT-03: no Stop hook entry"
    agt03=1
  fi
  if ! printf '%s\n' "$wfm" | grep -qF '~/.claude/agents/mission/hooks/require-handoff.sh'; then
    note "AGT-03: require-handoff.sh not referenced via ~/.claude install path"
    agt03=1
  fi
  # Hook commands must be install paths, never repo-relative kit/ paths.
  if printf '%s\n' "$wfm" | grep 'command' | grep -q 'kit/agents'; then
    note "AGT-03: hook command uses a repo-relative kit/agents path"
    agt03=1
  fi
fi
result AGT-03 "$agt03"

# ---------------------------------------------------------------------------
# AGT-04: mission-reviewer tools are read-safe only — every declared tool in
#         {Read, Grep, Glob, Bash}; neither Edit nor Write appears.
# ---------------------------------------------------------------------------
agt04=0
if [ ! -f "$REVIEWER" ]; then
  note "AGT-04: missing $REVIEWER"
  agt04=1
else
  tools_line="$(frontmatter "$REVIEWER" | grep '^tools:')"
  if [ -z "$tools_line" ]; then
    note "AGT-04: mission-reviewer has no tools: field"
    agt04=1
  else
    tools_val="${tools_line#tools:}"
    # Every declared tool must be in the allowlist.
    for t in $(printf '%s\n' "$tools_val" | tr ',' '\n'); do
      t="$(printf '%s' "$t" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
      [ -z "$t" ] && continue
      case "$t" in
        Read|Grep|Glob|Bash) : ;;
        *) note "AGT-04: tool '$t' outside allowlist {Read, Grep, Glob, Bash}"; agt04=1 ;;
      esac
    done
    case "$tools_val" in
      *Edit*)  note "AGT-04: tools value contains Edit";  agt04=1 ;;
    esac
    case "$tools_val" in
      *Write*) note "AGT-04: tools value contains Write"; agt04=1 ;;
    esac
  fi
fi
result AGT-04 "$agt04"

# ---------------------------------------------------------------------------
# AGT-05: mission-scrutiny can spawn nested reviewers — word-boundary 'Agent'
#         present in its tools line.
# ---------------------------------------------------------------------------
agt05=0
if [ ! -f "$SCRUTINY" ]; then
  note "AGT-05: missing $SCRUTINY"
  agt05=1
else
  if ! frontmatter "$SCRUTINY" | grep '^tools:' | grep -qw 'Agent'; then
    note "AGT-05: mission-scrutiny tools line lacks Agent"
    agt05=1
  fi
fi
result AGT-05 "$agt05"

# ---------------------------------------------------------------------------
# AGT-06: mission-flow-validator declares an inline headless Playwright MCP
#         server; no other agent declares mcpServers.
# ---------------------------------------------------------------------------
agt06=0
if [ ! -f "$FLOW" ]; then
  note "AGT-06: missing $FLOW"
  agt06=1
else
  ffm="$(frontmatter "$FLOW")"
  if ! printf '%s\n' "$ffm" | grep -q 'playwright'; then
    note "AGT-06: no playwright server entry in flow-validator frontmatter"
    agt06=1
  fi
  if ! printf '%s\n' "$ffm" | grep -q 'type: stdio'; then
    note "AGT-06: playwright entry missing type: stdio"
    agt06=1
  fi
  if ! printf '%s\n' "$ffm" | grep -q 'command: npx'; then
    note "AGT-06: playwright entry missing command: npx"
    agt06=1
  fi
  if ! printf '%s\n' "$ffm" | grep -qF '@playwright/mcp@latest'; then
    note "AGT-06: args missing @playwright/mcp@latest"
    agt06=1
  fi
  if ! printf '%s\n' "$ffm" | grep -qF -- '--headless'; then
    note "AGT-06: args missing --headless"
    agt06=1
  fi
fi
for f in "$WORKER" "$SCRUTINY" "$REVIEWER"; do
  if [ -f "$f" ] && grep -q 'mcpServers' "$f"; then
    note "AGT-06: $(basename "$f") declares mcpServers (only flow-validator may)"
    agt06=1
  fi
done
result AGT-06 "$agt06"

# ---------------------------------------------------------------------------
# AGT-SHAPE-REVIEWER (non-contract): mission-reviewer restates the exact
#         report keys immediately before the write-the-report step — forbids
#         the synonym keys observed drifting in the second e2e run
#         ('status' NOT 'verdict'; 'issues' NOT 'blockingIssues' /
#         'nonBlockingIssues'), ships a minimal valid example JSON, and
#         mandates `date -u +%Y-%m-%dT%H-%M-%SZ` for filename timestamps.
# ---------------------------------------------------------------------------
shape_rev=0
if [ ! -f "$REVIEWER" ]; then
  note "AGT-SHAPE-REVIEWER: missing $REVIEWER"
  shape_rev=1
else
  if ! grep -qF 'NOT "verdict"' "$REVIEWER"; then
    note "AGT-SHAPE-REVIEWER: no anti-synonym rule (status, NOT \"verdict\")"
    shape_rev=1
  fi
  if ! grep -qF 'NOT "blockingIssues"' "$REVIEWER" || ! grep -qF '"nonBlockingIssues"' "$REVIEWER"; then
    note "AGT-SHAPE-REVIEWER: no anti-synonym rule forbidding blockingIssues/nonBlockingIssues"
    shape_rev=1
  fi
  if ! grep -qF '"issues": []' "$REVIEWER"; then
    note "AGT-SHAPE-REVIEWER: no minimal valid example JSON (with an empty issues array)"
    shape_rev=1
  fi
  if ! grep -qF 'date -u +%Y-%m-%dT%H-%M-%SZ' "$REVIEWER"; then
    note "AGT-SHAPE-REVIEWER: no date -u filename-timestamp mandate"
    shape_rev=1
  fi
fi
result AGT-SHAPE-REVIEWER "$shape_rev"

# ---------------------------------------------------------------------------
# AGT-SHAPE-FLOW (non-contract): mission-flow-validator gets the same
#         treatment for its report AND its handoff content — forbids
#         'verdict', mandates skillFeedback as an OBJECT (never a string),
#         mandates commandsRun entries as {command, exitCode, observation}
#         objects (never plain strings), and mandates the date -u timestamp.
# ---------------------------------------------------------------------------
shape_flow=0
if [ ! -f "$FLOW" ]; then
  note "AGT-SHAPE-FLOW: missing $FLOW"
  shape_flow=1
else
  if ! grep -qF 'NOT "verdict"' "$FLOW"; then
    note "AGT-SHAPE-FLOW: no anti-synonym rule (status, NOT \"verdict\")"
    shape_flow=1
  fi
  if ! grep -F 'skillFeedback' "$FLOW" | grep -qF 'never a string'; then
    note "AGT-SHAPE-FLOW: no rule that skillFeedback is an object, never a string"
    shape_flow=1
  fi
  if ! grep -qF '{followedProcedure, deviations, suggestedChanges}' "$FLOW"; then
    note "AGT-SHAPE-FLOW: skillFeedback object keys not restated"
    shape_flow=1
  fi
  if ! grep -qF '{command, exitCode, observation}' "$FLOW"; then
    note "AGT-SHAPE-FLOW: commandsRun entry object shape not restated"
    shape_flow=1
  fi
  if ! grep -F 'commandsRun' "$FLOW" | grep -qF 'never plain strings'; then
    note "AGT-SHAPE-FLOW: no rule that commandsRun entries are objects, never plain strings"
    shape_flow=1
  fi
  if ! grep -qF 'date -u +%Y-%m-%dT%H-%M-%SZ' "$FLOW"; then
    note "AGT-SHAPE-FLOW: no date -u filename-timestamp mandate"
    shape_flow=1
  fi
fi
result AGT-SHAPE-FLOW "$shape_flow"

# ---------------------------------------------------------------------------
# AGT-SHAPE-SCRUTINY (non-contract): mission-scrutiny's collect-reviews step
#         validates each review with jq (status pass|fail, issues array,
#         synonym keys rejected) and re-spawns a malformed review's reviewer
#         once before failing the synthesis.
# ---------------------------------------------------------------------------
shape_scr=0
if [ ! -f "$SCRUTINY" ]; then
  note "AGT-SHAPE-SCRUTINY: missing $SCRUTINY"
  shape_scr=1
else
  if ! grep -qF '.status == "pass" or .status == "fail"' "$SCRUTINY"; then
    note "AGT-SHAPE-SCRUTINY: jq validation lacks the status pass|fail check"
    shape_scr=1
  fi
  if ! grep -qF '.issues | type == "array"' "$SCRUTINY"; then
    note "AGT-SHAPE-SCRUTINY: jq validation lacks the issues-array check"
    shape_scr=1
  fi
  if ! grep -qF 'has("verdict")' "$SCRUTINY"; then
    note "AGT-SHAPE-SCRUTINY: jq validation does not reject synonym keys (verdict/blockingIssues/nonBlockingIssues)"
    shape_scr=1
  fi
  if ! grep -qF 're-spawn that reviewer once' "$SCRUTINY"; then
    note "AGT-SHAPE-SCRUTINY: no re-spawn-once rule for malformed reviews"
    shape_scr=1
  fi
fi
result AGT-SHAPE-SCRUTINY "$shape_scr"

# ---------------------------------------------------------------------------
# SKL-SHAPE-HANDOFF (non-contract): mission-run's validate-the-handoff step
#         shape-checks the handoff with jq (skillFeedback is an object,
#         commandsRun items are objects) and re-prompts the worker once on
#         a malformed shape.
# ---------------------------------------------------------------------------
skl_shape=0
if [ ! -f "$RUN_SKILL" ]; then
  note "SKL-SHAPE-HANDOFF: missing $RUN_SKILL"
  skl_shape=1
else
  if ! grep -qF '.handoff.skillFeedback | type == "object"' "$RUN_SKILL"; then
    note "SKL-SHAPE-HANDOFF: no jq check that skillFeedback is an object"
    skl_shape=1
  fi
  if ! grep -F '.handoff.verification.commandsRun' "$RUN_SKILL" | grep -qF 'all(type == "object")'; then
    note "SKL-SHAPE-HANDOFF: no jq check that commandsRun items are objects"
    skl_shape=1
  fi
  if ! grep -qF 're-prompt the same agent ONCE' "$RUN_SKILL"; then
    note "SKL-SHAPE-HANDOFF: no re-prompt-once rule for malformed handoff shapes"
    skl_shape=1
  fi
fi
result SKL-SHAPE-HANDOFF "$skl_shape"

exit $STATUS
