# Claude Code Missions

Run multi-hour, unattended coding missions in Claude Code: plan a feature queue once, then a runner loop executes it with a **fresh agent per feature**, **hook-enforced evidence handoffs**, and **milestone validation gates** — resumable across sessions. Pure bash + jq, nothing else to install, and the kit's own test suite snapshot-diffs `~/.claude` to prove the uninstall restores it exactly.

It reproduces the core of [Factory.ai's Droid Missions](https://factory.ai) using only native Claude Code primitives: subagents, per-agent hooks, skills, and `/goal`.

## Why

Claude Code is great at *tasks*. It is weak at *projects*.

Ask it to build something that takes four hours and you hit the same three walls every time: the session's context fills up and quality rots, "keep going" prompts drift away from the original plan, and nothing ever *checks* that the work claimed done was actually done. You end up babysitting — re-prompting, re-explaining, re-verifying by hand.

The tools people already reach for each solve one piece and miss the others:

| Approach | Fresh context per unit of work | State survives the session | Verification is enforced | Runs unattended |
|---|---|---|---|---|
| One long session + `/goal "keep going"` | no — one context all the way | no | no — the model grades itself | yes |
| Spawning subagents by hand | yes | no — gone when the session ends | no | no |
| ultracode / Workflow fan-outs (Claude Code's one-turn parallel-subagent orchestration) | yes | no — one turn's orchestration | partially (verify stages) | no — not resumable |
| **Missions (this kit)** | **yes — one worker per feature** | **yes — files in your repo, git-committed** | **yes — hooks + separate validator agents** | **yes — `/goal` loop, hours** |

A mission combines all four: durable file-based state (`mission/` in your target repo), a fresh worker subagent per feature, a `Stop` hook that rejects a worker's exit until it files an evidence-backed handoff JSON, and milestone gates where *separate* reviewer and flow-validator agents check the work before the queue moves on. A `/goal` condition drives the loop so it keeps going without you.

This isn't hypothetical dogfooding: the kit was itself built by a mission system, and its own end-to-end test is a real unattended `claude -p "/mission-run"` run that implemented a small CLI from a pre-authored mission — 21 commits, a sealed milestone, all 8 contract assertions passed, clean tree at the end, ~19 minutes, zero human input.

## 60-second quick start

```bash
git clone https://github.com/rajinsyed/claude-code-missions
cd claude-code-missions
./install.sh
```

Restart Claude Code once so it picks up the new skills. Then, in the repo you want to work on:

1. `/mission-plan` — an interactive 8-phase planning conversation (in plan mode, with explicit confirmation gates). It ends by scaffolding a complete `mission/` dir in your repo and printing the exact run command.
2. `/mission-run` — the session becomes the orchestrator and starts the loop. Watch it tick, interrupt any time, or run it headless overnight (see below).

Want to see it work before pointing it at your own code? `toy-mission/` is a runnable end-to-end fixture — a pre-authored mission for a tiny `wordstats` CLI. `toy-mission/README.md` walks you through copying it into a scratch repo and running it unattended.

## How it works

`/mission-plan` scaffolds a `mission/` directory inside your target repo. That directory *is* the mission — every piece of state lives in files, gets git-committed, and survives session death:

```
mission/
├── mission.md               # scope and success criteria
├── architecture.md          # design decisions workers must follow
├── features.json            # THE QUEUE: ordered features with milestones,
│                            #   statuses, attempt counts
├── validation-contract.md   # Given/When/Then assertions with IDs
├── validation-state.json    # each assertion: pending → passed/failed
├── AGENTS.md                # accreted per-repo knowledge for workers
├── services.yaml            # programmatic check commands (test, lint, ...)
├── library/                 # environment notes, gotchas discovered mid-run
├── handoffs/                # one evidence JSON per completed feature
├── evidence/                # flow-validation artifacts (transcripts, output)
├── validation/              # per-milestone scrutiny reviews, synthesis
│                            #   verdicts, and user-testing reports
├── triage-log.md            # what scrutiny did with discovered issues
└── progress_log.jsonl       # append-only event log (the observability surface)
```

`/mission-run` then drives this loop, with `/goal` keeping it alive between turns:

```
/mission-run  ──►  /goal loop (orchestrator: reads state, never edits code)
      │
      ▼
 next pending feature in milestone order
      │
      ▼
┌─────────────────────────────────────────────────────┐
│  mission-worker · FRESH CONTEXT, exactly 1 feature  │
│  tests first → implement → git commit →             │
│  handoff JSON (a Stop hook rejects finishing        │
│  without one; a PreToolUse hook blocks the worker   │
│  from editing the queue and verdict files)          │
└──────────────────────────┬──────────────────────────┘
                           ▼
        orchestrator validates the handoff shape,
        triages discoveredIssues, updates the queue
                           │
              milestone complete? ──no──► next feature
                           │yes
                           ▼
┌──────────────────────────┐  ┌───────────────────────────┐
│ mission-scrutiny         │  │ mission-flow-validator    │
│ runs services.yaml       │  │ exercises the contract    │
│ checks + fans out one    │  │ assertions through the    │
│ mission-reviewer per     │  │ REAL user surface (CLI /  │
│ completed feature        │  │ browser), saves evidence  │
└──────────────────────────┘  └───────────────────────────┘
                           │
                           ▼
        milestone sealed → next milestone, or the
        /goal condition is met and the run ends
```

Why a fresh worker per feature instead of one long session? Because context is a consumable. A worker spawned for feature 7 starts with the architecture doc, the accreted `AGENTS.md` knowledge, and its one feature description — not 200k tokens of the previous six features' debugging detours. Each worker reads the distilled state, does one job well, and writes its evidence down. Sequential-by-default is a feature here, not a limitation: feature 8 gets to build on a *validated* feature 7, and a failed feature gets retried (up to 3 attempts) or marked `blocked` instead of silently poisoning everything after it.

The handoff is the load-bearing piece. A worker cannot mark itself done by just *saying* so — the `Stop` hook (`require-handoff.sh`) rejects the agent's exit until a schema-valid handoff JSON exists in `mission/handoffs/`, carrying the commit id, the commands it ran with their exit codes, and any issues it discovered. A second hook (`guard-mission-state.sh`) blocks workers from editing `features.json` and `validation-state.json` — the queue and the verdicts — so a worker can't grade its own homework. Then at milestone boundaries, scrutiny re-runs the programmatic checks and puts *different* reviewer agents on each feature's diff, and the flow validator drives the actual user surface — a CLI gets really invoked, a web app gets really clicked.

Resume is free because state is files: re-invoking `/mission-run` re-reads everything from disk, resets any feature left `in_progress` without a handoff back to `pending`, and continues. Completed features stay marked done and aren't re-queued.

## The reversibility guarantee

I wanted this to be something you can try without fear of it haunting your `~/.claude` forever. Concretely:

- `install.sh` copies **exactly three namespaced paths** — `agents/mission/`, `skills/mission-plan/`, `skills/mission-run/` — into `~/.claude`, and records every created path in one manifest file, `~/.claude/mission-kit-manifest.txt` (13 entries on a typical install; a few more if it had to create `~/.claude` or its parent dirs itself). It refuses to overwrite anything pre-existing unless you pass `--force`.
- `uninstall.sh` removes exactly the manifest's paths and nothing else. The test suite snapshot-diffs `find ~/.claude` before install and after uninstall (in a sandboxed fake home) and requires them byte-identical — including the pristine-machine case where `~/.claude` didn't exist at all.
- Installed but not invoked, the kit has **zero impact on normal sessions**: no `settings.json` edits, no global hooks (all hooks live in the mission agents' frontmatter and only run while a mission agent runs), both skills carry `disable-model-invocation: true` so they only fire when you type them, and every agent description forbids delegation outside a mission run.

Per-mission `mission/` dirs live in the repos you ran missions in; delete them per repo if you want them gone.

## Running unattended (headless)

```bash
claude -p "/mission-run" --permission-mode acceptEdits
```

runs the whole loop non-interactively to completion. One trap to know about first: headless `claude -p` in an **untrusted** workspace denies all Bash invocations ("This command requires approval") even with `--permission-mode acceptEdits` — acceptEdits covers file edits, not Bash — which deadlocks the run. Before a headless run in a repo Claude Code hasn't trusted yet:

1. Resolve the repo's real path with `pwd -P` (e.g. `mktemp -d` returns `/tmp/...` but Claude Code keys projects by the resolved `/private/tmp/...` path).
2. Add a trust entry for that resolved path in `~/.claude.json` (the session/trust DB, not `~/.claude/settings.json`):

   ```bash
   REPO="$(pwd -P)"
   [ -f ~/.claude.json ] || echo '{}' > ~/.claude.json
   tmp="$(mktemp)" && jq --arg p "$REPO" \
     '.projects[$p].hasTrustDialogAccepted = true' ~/.claude.json > "$tmp" \
     && mv "$tmp" ~/.claude.json
   ```

3. Allow Bash in the repo's project settings:

   ```bash
   mkdir -p .claude
   printf '{"permissions":{"allow":["Bash"]}}\n' > .claude/settings.json
   ```

Interactive sessions don't need any of this — the trust dialog and live permission prompts handle it. `toy-mission/README.md` shows the same steps applied to a scratch repo.

## Requirements

- Claude Code **≥ 2.1.139** (for `/goal`; the kit was developed and end-to-end tested against 2.1.202)
- macOS or Linux
- `jq` and `git`
- Nothing else — the kit is bash 3.2-compatible (yes, it runs on macOS's ancient stock bash)

## Uninstall

```bash
cd claude-code-missions
./uninstall.sh
```

`uninstall.sh` removes exactly the paths recorded in `~/.claude/mission-kit-manifest.txt` (files first, then now-empty directories), then the manifest itself — restoring `~/.claude` to its pre-install state. Then delete the cloned repo to remove everything else.

## Known Gaps vs Factory

Three deliberate v1 gaps, documented rather than papered over:

1. **Handoff arbitration is model-enforced, not platform-blocked.** The `/goal` condition and skill instructions require valid handoffs, and the `Stop` hook blocks a worker from finishing without one — but there is no platform-level arbiter like Factory's; a sufficiently confused model could still mis-record state.
2. **Orchestrator role separation is instructional in the main session.** The `/mission-run` skill forbids the orchestrator from editing repo code (all code changes go through workers), but nothing hard-blocks the main session from doing so. Hard enforcement is available via the `claude --agent` pattern — running the orchestrator itself as a restricted agent definition with no code-edit tools — documented here as an optional advanced mode, not built in v1.
3. **No runner UI.** There is no dashboard; `progress_log.jsonl` (append-only event log in the mission dir) plus the `/goal` status indicator are the observability surface for a running mission.

## FAQ

**Does this replace ultracode / Workflow orchestration?**
No — they're orthogonal. Workflows are one-turn parallel fan-out; missions are a durable, gated, sequential queue. A mission worker can still use workflows *inside* its feature when the feature benefits from fan-out.

**What does it cost?**
More tokens than a single long session — fresh contexts re-read the mission docs, and scrutiny/flow validation spawn extra agents. That's the price of verification. If you just want a quick task done, use a normal session; missions are for work you'd otherwise have to keep checking up on.

**Can I run it overnight?**
Yes — `claude -p "/mission-run" --permission-mode acceptEdits` (see the headless prerequisites above). The toy mission is the low-stakes way to build confidence first.

**What happens when a feature fails?**
The attempt is counted, the feature goes back to `pending`, and a later worker retries with the reviewer's feedback available. After 3 failed attempts it's marked `blocked` and the run moves on (or stops, if everything remaining depends on it) instead of thrashing. The runner also stops after 150 turns as a hard safety valve.

## Contributing

The test suite is the contract — it's local-first, no CI needed:

```bash
bash tests/run-all.sh   # 37 structural tests across 8 scripts, must all PASS
```

The tests pin exact strings in the agent, skill, and README files (isolation sentences, hook wiring, schema shapes, this README's Known Gaps section), so run the suite after *any* edit. Installer tests run against sandboxed fake homes created with `mktemp -d` and never touch your real `~/.claude`. The kit is 4 subagents, 2 skills, 2 hooks, and 2 shell scripts — small enough to read in one sitting, and PRs that keep it that way are welcome.

## License

[MIT](LICENSE)
