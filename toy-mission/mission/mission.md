# Mission — wordstats: a tiny bash+awk word statistics CLI

## Goal

Build `wordstats`, a single-file bash+awk command-line tool that, given a text file argument, prints:

1. the total word count,
2. the number of unique words,
3. the top 3 most frequent words with their counts (descending frequency).

No dependencies beyond bash and awk. The tool lives in one file (`wordstats.sh`) with a test runner at `tests/wordstats_test.sh`.

## Milestones

### Milestone 1 (only milestone)

- **f1 — core counting logic + test script**: word counting, unique-word counting, top-3 frequency output; `tests/wordstats_test.sh` covering them against a fixture text.
- **f2 — CLI arg parsing, --help, error handling**: usage message, `--help`, missing-argument and missing-file errors with non-zero exits.
- **f3 — README + edge cases**: repo README documenting usage; empty-file edge case handled and tested.
- Milestone gate: scrutiny (test command + per-feature reviews) and flow validation (TOY-01..TOY-08 through the real CLI via Bash).

## Proposal summary

A deliberately tiny mission: one milestone, three implementation features, eight contract assertions (TOY-01..TOY-08) on the CLI surface. Success = `bash tests/wordstats_test.sh` green, all TOY assertions passing through real CLI invocations, milestone sealed.
