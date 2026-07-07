# Mission Guidance — <mission title>

<!-- Mission-wide rules every worker reads FIRST, before touching anything. The orchestrator may update this mid-mission; workers always read the latest version. -->

Working directory: `<absolute path to the target repo>`

## Read first

<!-- Ordered reading list for workers: architecture.md, validation-contract.md (their fulfills assertions), library/ files relevant to the stack. -->

## Hard rules

<!-- Numbered, non-negotiable rules. Include at minimum:
1. Mission boundaries — ports, off-limits paths/services, network restrictions.
2. Technology constraints — mandated tools/libraries; substitutions forbidden.
3. TDD / testing expectations and the exact gate command.
4. Repo hygiene — clean git status at handoff, commit message style.
5. Who may write mission state (features.json, validation-state.json are orchestrator-only). -->

1.

## Programmatic gate (run before every handoff)

```bash
# <exact command(s) every worker must run and record, e.g. the services.yaml test command>
```

## Handoff requirements

<!-- What verification.commandsRun must include; any feature-specific evidence expectations. -->

## Known pre-existing issues

<!-- Issues workers should NOT re-report or go off-track fixing. -->
