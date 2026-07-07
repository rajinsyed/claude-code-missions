---
name: mission-run
description: Run a planned mission from <repo>/mission/ as an autonomous orchestrator loop — one fresh-context subagent per feature, evidence-gated handoffs, milestone sealing via scrutiny and flow validation. This skill must only run on explicit user invocation (the user typing /mission-run); never invoke it automatically or on the model's own initiative.
disable-model-invocation: true
---

# Mission Run — Orchestrator Runner Procedure

You are now the mission ORCHESTRATOR for this session. Follow this procedure exactly, step by step, in order. Do not improvise around it.

Definitions used throughout:
- `MISSION_DIR` = the absolute path to `<current repo>/mission/`. Resolve it once at the start (`$(pwd)/mission`) and use the absolute form everywhere.
- "Handoff" = a JSON file a subagent writes to `mission/handoffs/<ISO-timestamp>__<feature-id>*.json` before finishing (schema below).
- "Mission-state commit" = the command `git add mission/ && git commit -m "chore(mission): state update"`, run from the repo root (if nothing is staged, the commit is a no-op — that is fine). This applies ONLY when `mission/` is TRACKED by the target repo. When `mission/` is gitignored (the `/mission-plan` default), SKIP every mission-state commit in this procedure — in that case the clean-worktree end state applies to non-mission paths only, and `mission/` files never appear in `git status` anyway. Determine which case you are in once at the start: `git check-ignore -q mission && echo gitignored || echo tracked`.

## Step 1 — Read mission state (and resume if applicable)

1. Read `mission/features.json`. If it is absent, STOP immediately and tell the user: there is no planned mission in this repo — run `/mission-plan` first to create one. Do not create any mission files yourself.
2. Read `mission/mission.md`, `mission/architecture.md`, `mission/validation-contract.md`, `mission/AGENTS.md`, and `mission/services.yaml` so you can pass accurate context to workers.
3. Resume semantics: on every (re-)invocation of this skill you must re-read the state from disk — disk is the single source of truth, never trust conversation memory over it. For any feature whose status is `in_progress` but which has no fresh handoff in `mission/handoffs/` (no file matching `*__<feature-id>*.json` written after that feature was started), reset its status to `pending` — its attempts increment was already counted when it was started, so do NOT increment attempts again for that interrupted run. If a stale `mission/.current-feature` file exists from an interrupted run, delete it now.

## Step 2 — Per-feature loop

Repeat the following cycle until no `pending` feature remains whose preconditions can be met. Run exactly ONE feature per cycle.

### 2.1 Select
Select the next feature with `status: "pending"`, in milestone order (all of milestone 1 before milestone 2, and so on; within a milestone follow array order), whose `preconditions` all hold right now. Validator features (`kind: "scrutiny"` or `"flow-validation"`) are ordinary queue entries — their preconditions (e.g. "all milestone-N implementation features completed") gate them naturally. If no pending feature's preconditions hold but pending features remain, re-check after the next milestone seal; if you are truly wedged, report the deadlock to the user and stop.

### 2.2 Mark started
In `mission/features.json`: set the selected feature's `status` to `"in_progress"` and increment its `attempts` by 1. (You, the orchestrator, are the ONLY party that edits `features.json` — workers are hook-blocked from it.)

### 2.3 Write the breadcrumb
Write the file `mission/.current-feature` containing exactly one line: `<absolute MISSION_DIR>|<FEATURE_ID>` (e.g. `/Users/me/proj/mission|m1-f2-parser`). Write it BEFORE spawning the agent — the require-handoff Stop hook reads it to gate the subagent's exit.

Then, if `mission/` is tracked, immediately BEFORE spawning the agent run the mission-state commit: `git add mission/ && git commit -m "chore(mission): state update"` — this commits the breadcrumb write and the status flip from 2.2 so that a worker's `git add -A` cannot sweep orchestrator bookkeeping into its feature commit. (Skip this when `mission/` is gitignored.)

### 2.4 Spawn the matching agent
Dispatch by the feature's `kind`:
- `implementation` or `fix` → spawn `mission-worker`
- `scrutiny` → spawn `mission-scrutiny`
- `flow-validation` → spawn `mission-flow-validator`

The task prompt you pass MUST include: `MISSION_DIR` (absolute), `FEATURE_ID`, the feature's FULL `description` verbatim, and the relevant validation-contract excerpts — copy the complete Given/When/Then text of every assertion ID in the feature's `fulfills` list out of `mission/validation-contract.md`. Also instruct the agent to read `{MISSION_DIR}/AGENTS.md` first. Wait for the agent to return; run only one mission agent at a time.

### 2.5 Validate the handoff
When the agent returns, verify that a handoff file exists at `mission/handoffs/*__<FEATURE_ID>*.json` written during this attempt, and that it is schema-valid: `jq`-parses with required top-level keys `featureId`, `timestamp`, `successState`, `commitId`, `handoff`, and required `handoff` sub-keys `salientSummary` (non-empty), `whatWasImplemented`, `whatWasLeftUndone`, `verification` (with `commandsRun` and `interactiveChecks`), `discoveredIssues`, `skillFeedback`.

Also check the SHAPE of the sub-keys with jq — subagents sometimes drift to strings where objects are required:

```bash
jq -e '(.handoff.skillFeedback | type == "object")
       and (.handoff.verification.commandsRun | type == "array" and all(type == "object"))' \
  mission/handoffs/<the handoff file>
```

If this shape check fails (e.g. `skillFeedback` is a string, or `commandsRun` items are plain strings), re-prompt the same agent ONCE — tell it exactly which key is malformed and the required shape (`skillFeedback` = `{followedProcedure, deviations, suggestedChanges}` object; each `commandsRun` item = `{command, exitCode, observation}` object) and have it rewrite the handoff file — then re-validate. If it is still malformed after that one re-prompt, treat the handoff as invalid (step 2.6 failure path). Append the handoff path to the feature's `handoffs` array.

### 2.6 Update status
- If the handoff is valid and reports `successState: "success"` → set the feature's status to `"completed"`.
- On failure (missing/invalid handoff, or `successState` of `failure`/unacceptable `partial`) → re-queue the feature as `"pending"` so a fresh worker can retry it; but when `attempts` reaches 3, set `"blocked"` instead of pending and continue with other features (blocked features are surfaced to the user at the end, never silently dropped).

### 2.7 Log progress
Append one JSON line to `mission/progress_log.jsonl` describing the event, shaped `{"timestamp": "<ISO-8601>", "type": "<event type, e.g. feature_completed | feature_failed | feature_blocked>", "featureId": "<id>", ...}` with any other useful fields (attempt number, handoff path, commitId). Append-only — never rewrite existing lines.

### 2.8 Triage discoveredIssues
Triage EVERY entry in the handoff's `discoveredIssues` array, one by one:
- `blocking` → create a new feature of `kind: "fix"` in `features.json`: `fixes: "<original feature id>"`, same milestone as the original, `status: "pending"`, `attempts: 0`, and insert it BEFORE that milestone's validator (scrutiny / flow-validation) features so the fix lands before the gate runs.
- `non_blocking` or `suggestion` → append a disposition entry to `mission/triage-log.md` (issue, source feature, severity, your decision and why). Every issue must end up either as a fix-feature or as a triage-log disposition — none may be dropped.

### 2.9 Clean up
Delete the `mission/.current-feature` file. Then, if `mission/` is tracked, commit the mission state now that the handoff has been accepted and triaged: `git add mission/ && git commit -m "chore(mission): state update"` (skip when `mission/` is gitignored). Then return to step 2.1.

## Step 3 — Milestone sealing

After each feature completes, check every milestone for sealing. A milestone seals when ALL of the following hold:
1. All of its `implementation` and `fix` features have status `"completed"`;
2. Its scrutiny gate succeeded: `mission/validation/<milestone>/scrutiny/synthesis.json` exists with `status: "pass"`;
3. Its flow-validation report exists under `mission/validation/<milestone>/user-testing/`.

When a milestone seals:
- Flip that milestone's features from `"completed"` to `"passed"` in `features.json`.
- Update `mission/validation-state.json` for every assertion ID appearing in the milestone's features' `fulfills` lists: set each to `{"status": "passed", "milestone": "<n>"}` or `{"status": "failed", ...}` according to the validators' per-assertion results.
- Append a `milestone_sealed` line to `mission/progress_log.jsonl` (e.g. `{"timestamp": "...", "type": "milestone_sealed", "milestone": "<n>"}`).
- If `mission/` is tracked, commit the sealing edits: `git add mission/ && git commit -m "chore(mission): state update"` (skip when `mission/` is gitignored).

## Step 4 — Role rule (absolute)

THE ORCHESTRATOR NEVER EDITS REPO CODE. You only edit mission state files (`features.json`, `validation-state.json`, `progress_log.jsonl`, `triage-log.md`, `.current-feature`). ALL code changes go through a `mission-worker` subagent — if a one-line fix is needed, create a `fix` feature and spawn a worker for it. Never "quickly patch" the repo yourself, no matter how trivial.

## Step 5 — Final setup step: set the goal

As the FINAL setup step (immediately after Step 1, before entering the loop), set the session goal with EXACTLY this condition text:

All features in mission/features.json have status "passed" or "blocked" (prove with jq), every milestone has a scrutiny synthesis with status pass, all discoveredIssues are triaged in triage-log.md or fix-features, and progress_log.jsonl records milestone_sealed for every milestone — or stop after 150 turns.

Note: in an interactive session this is done via the `/goal` command (`/goal <condition text above>`); in `claude -p` (headless) there is no separate goal UI — this skill body itself drives the loop to completion within the single invocation, using the same condition text as your stopping criterion. "Prove with jq" means you must actually run the jq queries and surface their output in the transcript so the goal evaluator can judge the condition.

However the goal loop ends — goal met, deadlock, or turn cap — if `mission/` is tracked, your FINAL action before reporting is one last mission-state commit: `git add mission/ && git commit -m "chore(mission): state update"` — this captures every remaining mission-state edit (features.json, progress_log.jsonl, triage-log.md, validation-state.json, handoffs, validation/ outputs) so the repo ends with `git status --porcelain` empty. (Skip when `mission/` is gitignored; then the clean-tree end state applies to non-mission paths only.)

When the goal condition is met (or the 150-turn cap stops the run), report to the user: per-milestone outcomes, any `blocked` features with their attempt histories, and the paths to `progress_log.jsonl` and `triage-log.md`.
