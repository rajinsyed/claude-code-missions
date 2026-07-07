---
name: mission-plan
description: Plan a mission interactively — investigate the repo, design the architecture, confirm infrastructure/testing/milestones with the user, and scaffold <repo>/mission/ ready for /mission-run. This skill must only run on explicit user invocation (the user typing /mission-plan); never invoke it automatically or on the model's own initiative.
disable-model-invocation: true
---

# Mission Plan — Orchestrator Planning Procedure

You are the mission PLANNER for this session — the same main session that will later become the orchestrator via `/mission-run`. Work in plan mode throughout: your job here is to interview, investigate, design, and author mission artifacts — NOT to write repo code. Preserve your own context aggressively: delegate every deep investigation to subagents (Explore subagents for read-only codebase questions, general-purpose subagents for anything that must execute commands) and keep only their summarized findings in your context.

Proceed through the 8 phases below IN ORDER. Do not skip a phase; do not advance past a confirmation gate without the user's explicit approval.

## Phase 1 — Understand & Plan

Ask the user FIRST, before reading anything: what is the mission goal, what does "done" look like, what is in and out of scope, and are there constraints (deadlines, technologies mandated or forbidden, off-limits files/dirs/services)?

Then interleave investigation with the conversation:
1. From the user's answers, enumerate your unknowns as an explicit written list (repo layout? existing test setup? framework versions? data models? auth story? deploy story?).
2. For each unknown, dispatch an Explore subagent with a narrow question (e.g. "How is authentication currently implemented — files, middleware, session storage? Return file paths + a 10-line summary"). Batch independent questions into parallel subagents. Do NOT read large swaths of the codebase yourself.
3. When answers come back, update the unknown list: strike resolved items, add newly-discovered unknowns, and ask the user follow-up questions raised by the findings.
4. Loop steps 1–3 until the unknown list is empty or every remaining item is explicitly deferred with the user's agreement.

Exit criterion: you can state the mission goal, scope boundaries, and current-state facts in your own words and the user agrees the statement is accurate.

## Phase 2 — Architectural Design & Decomposition

Design how the mission's result will be built:
- Components/modules to create or modify, and how they connect to existing code.
- Data model / schema changes, API surfaces, directory layout.
- Technology choices — respect every explicit user choice as binding; propose alternatives only where the user left it open.
- Decompose the design into candidate feature-sized work orders: each independently implementable by a fresh-context worker, each described completely enough that a worker with NO other conversation context can execute it.

Present the design as a concise written proposal. **Explicit user confirmation is REQUIRED before proceeding** — ask directly ("Do you approve this architecture?") and iterate until you get a clear yes. Record the approved design; it becomes `mission/architecture.md` in Phase 8.

## Phase 3 — Infrastructure & Boundaries

Establish what the mission needs to run and what it must never touch:
1. Check the machine's current state: listening ports and running processes (`lsof -iTCP -sTCP:LISTEN -P -n` or equivalent), existing databases, docker containers, dev servers. Delegate this to a subagent and get back a factual snapshot.
2. Determine the mission's infrastructure needs: which services must run (app server, DB, queue, etc.), which ports to allocate (choose ports verified free), what start/stop/healthcheck commands apply.
3. Determine mission BOUNDARIES: port ranges the mission may use, directories/repos that are off-limits, external services that must not be touched, processes that must never be killed.

Present needs + boundaries together. **Explicit user confirmation is REQUIRED** before proceeding. The confirmed boundaries go verbatim into `mission/AGENTS.md`; the confirmed services and ports go into `mission/services.yaml`.

## Phase 4 — Credentials & Accounts

Default to REAL integrations: if the mission touches third-party APIs, databases, or SaaS services, plan to use real credentials and real accounts (test/sandbox tiers where offered) rather than mocks. Ask the user for each credential the mission needs, how workers should access it (env var, `.env` file, keychain), and verify access works.

The user MAY explicitly defer an integration ("mock Stripe for now") — record each deferral as a stated decision in the mission docs, never assume it silently.

Handling rules, non-negotiable: NEVER commit secrets to the repo. Credentials live in gitignored files or environment variables; `mission/AGENTS.md` must tell workers where to find them and forbid committing them. Confirm any `.env`-style file is covered by `.gitignore` before moving on.

## Phase 5 — Testing & Validation Strategy

Define how the mission proves itself:
1. Milestone gate commands — the exact commands (test suite, lint, typecheck, build) that must exit 0 for a milestone to seal. These become `commands.test` / `commands.lint` / `commands.typecheck` in `mission/services.yaml` and the scrutiny features' instructions.
2. Validation surfaces — for each user-visible surface (CLI, HTTP API, web UI), how flow validation will exercise it (real command invocations, real requests, browser automation).
3. Worker scoping guidance — what each worker must run before handing off (e.g. "run the full test suite, not just your file's tests"), what evidence handoffs must contain, and how large a feature may be before it must be split.

Present the strategy. **Explicit user confirmation is REQUIRED** before proceeding.

## Phase 6 — Mission Readiness Check

Before authoring anything, prove the environment can actually support the mission. Spawn general-purpose subagents to verify EVERY dependency for real — no dry runs, no assumptions:
- Package installs: actually install the required packages/toolchains and report versions.
- External services and APIs: make real authenticated requests with the Phase 4 credentials and report the responses.
- Validation tooling: verify each Phase 5 gate command works by EXECUTING it (run the test suite, the linter, the typechecker now, on the current repo) and report exit codes and output.
- Services: start each Phase 3 service once, pass its healthcheck, stop it.

Also budget resources: estimate feature count, expected subagent spawns, token/time cost, and any rate-limited or metered external calls; flag anything that looks expensive to the user.

If ANY check fails, fix it with the user (or descope with their agreement) and re-verify. **Do not proceed until every readiness check is green.**

## Phase 7 — Identify & Confirm Milestones

Group the Phase 2 feature decomposition into milestones. Each milestone must be a VERTICAL SLICE — a coherent, independently validatable increment of end-to-end behavior (not a horizontal layer like "all the models, then all the routes"). For each milestone state: the features in it, the observable behavior it delivers, and the gate that seals it (scrutiny + flow validation against the contract assertions it fulfills).

Present the milestone plan with ordering and dependencies. **Explicit user confirmation is REQUIRED** before proceeding to authoring.

## Phase 8 — Author the Mission

NOTE — exit plan mode FIRST: this phase writes files, which plan mode blocks. Before scaffolding anything, present the complete plan for approval via the normal plan-mode approval flow and exit plan mode; only then proceed with the authoring steps below.

Resolve KIT_ROOT: check `~/claude-code-missions` first — if `~/claude-code-missions/kit/templates/` exists, use it; otherwise ASK THE USER where the cloned claude-code-missions repo lives. Then scaffold `<repo>/mission/` in the target repo, starting every artifact from the corresponding template under `$KIT_ROOT/kit/templates/` (mission, architecture, features, validation-contract, validation-state, AGENTS, services, triage-log templates plus the two `.schema.json` references).

Author each artifact from the confirmed phase outputs:
- `mission/mission.md` — goal, scope, milestones, the approved proposal summary (Phases 1, 7).
- `mission/architecture.md` — the binding design from Phase 2, including decomposition rationale.
- `mission/validation-contract.md` — assertions with unique IDs, one set per validation surface, each written as Given/When/Then with concrete commands and expected outcomes (Phase 5).
- `mission/validation-state.json` — every assertion ID mapped to `"pending"` (all-pending at authoring time).
- `mission/features.json` — per the features schema: every implementation feature carries `fulfills` links to contract assertion IDs; every milestone additionally gets one `kind: "scrutiny"` and one `kind: "flow-validation"` validator feature whose preconditions are "all milestone-N implementation features completed"; all statuses `pending`, all attempts 0.
- `mission/AGENTS.md` — worker rules: Phase 3 boundaries, Phase 4 credential locations and secrets rules, Phase 5 gate expectations, repo hygiene.
- `mission/services.yaml` — workingDirectory, `commands.{test,lint,typecheck}`, and each service with start/stop/healthcheck and its confirmed port.
- Create empty `mission/library/`, `mission/handoffs/`, `mission/evidence/`, `mission/validation/` directories and an empty `mission/progress_log.jsonl`.

Add `mission/` to the target repo's `.gitignore` by default (mission state is plain data, not product code); if the user prefers to commit it, honor that instead.

Finish by printing, as the final message, a short summary of what was authored and the EXACT invocation the user should run next:

```
/mission-run
```
