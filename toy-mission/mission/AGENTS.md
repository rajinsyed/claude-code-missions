# Mission Guidance — wordstats

Working directory: the repo root (the directory containing `mission/`).

## Read first

1. `mission/architecture.md` — the binding file layout and CLI contract.
2. `mission/validation-contract.md` — your feature's `fulfills` assertions are your acceptance criteria (exact outputs and exit codes).
3. `mission/library/environment.md` — environment facts.

## Hard rules

1. **Bash only, no dependencies.** The tool is bash + awk in a single file (`wordstats.sh`). No Node, Python, bun, brew installs, or external packages — for the tool OR the tests.
2. **File layout is fixed** per `mission/architecture.md`: `wordstats.sh`, `README.md`, `tests/wordstats_test.sh`. Do not add other source files.
3. **Run `bash tests/wordstats_test.sh` from the repo root before handing off** and record the exit code in your handoff's `verification.commandsRun`. Never hand off with a failing suite.
4. **Mission state is orchestrator-only**: never edit `mission/features.json` or `mission/validation-state.json` (hook-enforced).
5. **Repo hygiene**: commit your work (`git add -A && git commit`) so `git status --porcelain` is clean at handoff; keep `wordstats.sh` executable.
6. **No network access needed** — everything is local files.

## Programmatic gate (run before every handoff)

```bash
bash tests/wordstats_test.sh   # exit 0, all PASS lines
git status --porcelain          # empty after your commit
```

## Handoff requirements

`verification.commandsRun` must include the gate command above with its observed exit code, plus at least one direct `wordstats.sh` invocation demonstrating your feature's behavior (command, exit code, observed output).
