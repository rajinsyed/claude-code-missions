# Validation Contract — <mission title>

<!-- The acceptance criteria for the whole mission. Every assertion has a stable ID (AREA-NN); features reference these IDs in their fulfills arrays, and validation-state.json tracks each ID from "pending" to passed/failed at milestone sealing. -->

Surfaces:

<!-- List each surface assertions are tested through, e.g.:
- **structural (tests/run-all.sh)** — programmatic checks run from the repo root; exit 0 = green
- **browser** — real UI via Playwright, headless
- **cli** — the built binary/script invoked via Bash
- **manual-user** — deferred to the human user; validators must NOT attempt -->

---

## Area: <area name> (<surface>)

<!-- One subsection per assertion. Keep IDs stable once features reference them. Copy this shape for every assertion: -->

### ABC-01: <one-line assertion summary>
- **Surface**: <which surface from the list above>
- **Priority**: <critical | high | medium | low>
- **Given**: <preconditions and fixtures — exact paths, exact seed data>
- **When**: <the action performed — exact commands where applicable>
- **Then**: <observable outcome — exact exit codes, strings, file contents>
