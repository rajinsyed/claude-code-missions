# Toy Mission — `wordstats` (end-to-end fixture)

A complete, pre-authored mission dir for a tiny bash+awk CLI (`wordstats`). It exists so the end-to-end test exercises the RUNNER (`/mission-run`), not planning: copy `mission/` into a fresh scratch repo, run Claude Code headless, and verify the artifacts the run produces.

## How to execute the e2e run

1. **Install the kit** (this is the one step that touches your real `~/.claude`):

   ```bash
   cd ~/claude-code-missions
   ./install.sh
   ```

2. **Create a fresh scratch repo under `/tmp`, copy the fixture in, and make the scaffold commit** — creating the scratch `.claude/settings.json` Bash allowlist BEFORE the commit so it is INCLUDED in it (otherwise the untracked `.claude/` dir dirties the tree and breaks E2E-04's clean-tree check):

   ```bash
   SCRATCH="$(mktemp -d /tmp/toy-wordstats.XXXXXX)"
   cd "$SCRATCH"
   git init
   cp -R ~/claude-code-missions/toy-mission/mission ./mission

   # Allow Bash in the scratch repo's project settings — created NOW so the
   # scaffold commit below picks it up (part of the headless-trust setup;
   # see step 3 for why it is needed).
   mkdir -p "$SCRATCH/.claude"
   printf '{"permissions":{"allow":["Bash"]}}\n' > "$SCRATCH/.claude/settings.json"

   git add -A
   git commit -m "chore: initial scaffold (pre-authored toy mission dir)"
   ```

   The initial scaffold commit matters: E2E-04 counts implementation-feature commits *excluding* it, and requires `git status --porcelain` to be EMPTY at the end of the run.

3. **Trust the scratch repo for headless Bash** (REQUIRED before `claude -p`; skipping this deadlocks the run):

   Headless `claude -p` in an untrusted workspace denies ALL Bash invocations ("This command requires approval") regardless of `--permission-mode acceptEdits` — acceptEdits covers file edits, not Bash. A fresh `mktemp -d` repo is untrusted by default, so alongside the `.claude/settings.json` allowlist committed in step 2, pre-seed a trust entry:

   ```bash
   # (1) Resolve the real path. mktemp returns /tmp/... but Claude Code keys
   #     projects by the resolved /private/tmp/... path.
   SCRATCH_REAL="$(cd "$SCRATCH" && pwd -P)"

   # (2) Add a trust entry for the resolved path in ~/.claude.json
   #     (the session/trust DB — NOT ~/.claude/settings.json; created
   #     empty first if it does not exist yet).
   [ -f ~/.claude.json ] || echo '{}' > ~/.claude.json
   tmp="$(mktemp)" && jq --arg p "$SCRATCH_REAL" \
     '.projects[$p].hasTrustDialogAccepted = true' ~/.claude.json > "$tmp" \
     && mv "$tmp" ~/.claude.json
   ```

   Interactive sessions do **not** need any of this — the trust dialog and live permission prompts handle it.

   **Cleanup note:** each e2e run leaves a trust entry behind, so `/private/tmp/toy-wordstats.*` projects accumulate in `~/.claude.json`. Harmless, but after testing you can prune them:

   ```bash
   tmp="$(mktemp)" && jq '.projects |= with_entries(
       select(.key | startswith("/private/tmp/toy-wordstats.") | not))' \
     ~/.claude.json > "$tmp" && mv "$tmp" ~/.claude.json
   ```

4. **Run the mission unattended** from the scratch repo root, exactly once:

   ```bash
   claude -p "/mission-run" --permission-mode acceptEdits
   ```

   Do not interrupt or timeout-kill the process; let it terminate by itself (E2E-01).

5. **Verify** the produced artifacts:

   ```bash
   bash ~/claude-code-missions/tests/test-e2e-artifacts.sh "$SCRATCH"
   ```

   This checks the E2E-01..E2E-08 assertions (features all `passed`, schema-valid handoffs, scrutiny fan-out reviews, flow-validation report, milestone sealed, no stray state).

## Assertion map — TOY-01..08 → E2E checks

The TOY-* assertions live in `mission/validation-contract.md` and describe the `wordstats` CLI surface. During the run they are tested by the `mission-flow-validator` agent through real Bash invocations; after the run they are verified indirectly through the E2E checks on the artifacts:

| TOY assertion | What it asserts | Verified by |
|---|---|---|
| TOY-01 | No argument → usage error on stderr, non-zero exit | E2E-06 (flow report covers every TOY-* with evidence); re-runnable manually per the contract |
| TOY-02 | Missing file → error naming the file, non-zero exit | E2E-06 |
| TOY-03 | `--help` → usage text, exit 0 | E2E-06 |
| TOY-04 | Correct total word count on the fixture text | E2E-06; also exercised by `tests/wordstats_test.sh` (E2E-04 commit gate) |
| TOY-05 | Correct unique word count on the fixture text | E2E-06 |
| TOY-06 | Top-3 words in descending frequency order | E2E-06 |
| TOY-07 | Empty file → zero counts, exit 0 | E2E-06 |
| TOY-08 | `bash tests/wordstats_test.sh` exits 0 | E2E-06; also the mission's `services.yaml` `commands.test` gate run by scrutiny (E2E-05) |

Additionally, milestone sealing must resolve every TOY-* key in `mission/validation-state.json` from `"pending"` to a passed/failed object (E2E-07).
