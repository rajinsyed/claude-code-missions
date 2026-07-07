# Architecture — wordstats

Binding design for this toy mission. Workers follow it exactly.

## File layout (the whole tool)

```
<repo root>/
├── wordstats.sh              # THE tool — single-file bash+awk CLI, executable
├── README.md                 # usage documentation (feature f3)
└── tests/
    └── wordstats_test.sh     # test runner — bash, no frameworks; exit 0 = green
```

No other source files. No dependencies beyond `bash` and `awk` (both preinstalled — see `library/environment.md`).

## wordstats.sh contract

- Invocation: `./wordstats.sh <file>` or `bash wordstats.sh <file>`.
- `--help` (or `-h`): print usage text containing the word `Usage` and the tool name to stdout; exit 0.
- No argument: print a usage error to stderr; exit non-zero.
- Argument is not a readable file: print an error naming the file to stderr; exit non-zero.
- Valid file: print to stdout, in order:
  1. a line with the total word count,
  2. a line with the unique word count,
  3. up to three lines listing the most frequent words with their counts, most frequent first (fewer lines if the file has fewer than 3 distinct words).
- Words are whitespace-separated tokens, compared case-insensitively (normalize to lowercase). Ties in frequency may be broken alphabetically.
- Empty file: total 0, unique 0, no top-words lines; exit 0.
- Implementation: bash for argument handling, a single awk program for the counting/frequency logic. Keep it in one file.

## tests/wordstats_test.sh contract

- Plain bash test runner: creates its own fixture files under `mktemp -d`, runs `wordstats.sh` against them, checks outputs and exit codes, prints per-case PASS/FAIL lines, exits 0 only if every case passes.
- Must cover at minimum: the counts on a known fixture text, top-3 ordering, missing-argument error, missing-file error, `--help`, and the empty-file edge case (i.e. the behaviors behind TOY-01..TOY-08).
- Run from the repo root as `bash tests/wordstats_test.sh` (this is the `services.yaml` `commands.test` gate).
