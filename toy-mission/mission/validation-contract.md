# Validation Contract — wordstats

Surfaces:
- **cli (Bash)** — every assertion below is tested by invoking `wordstats.sh` (or the test runner) directly via Bash from the repo root. No browser, no network.

All assertions are verified through the REAL CLI surface — run the commands, check the output and exit codes. Evidence: command transcripts/logs saved under `mission/evidence/1/`.

---

## Area: CLI argument handling

### TOY-01: Running with no argument prints a usage error and exits non-zero
- **Surface**: cli (Bash)
- **Priority**: critical
- **Given**: the repo root with `wordstats.sh` present
- **When**: `bash wordstats.sh` is run with no arguments
- **Then**: exit code is non-zero; stderr contains a usage message (mentions `Usage` or how to invoke the tool); stdout is not a stats report

### TOY-02: A missing input file produces an error naming the file and a non-zero exit
- **Surface**: cli (Bash)
- **Priority**: critical
- **Given**: `/tmp/definitely-does-not-exist.txt` does not exist
- **When**: `bash wordstats.sh /tmp/definitely-does-not-exist.txt` is run
- **Then**: exit code is non-zero; stderr names the missing file path

### TOY-03: --help prints usage text and exits 0
- **Surface**: cli (Bash)
- **Priority**: high
- **Given**: the repo root with `wordstats.sh` present
- **When**: `bash wordstats.sh --help` is run
- **Then**: exit code 0; stdout contains the word `Usage` and the tool name `wordstats`

## Area: Counting correctness

### TOY-04: Total word count is correct on a known fixture text
- **Surface**: cli (Bash)
- **Priority**: critical
- **Given**: a fixture file containing exactly: `the quick brown fox jumps over the lazy dog the fox` (11 whitespace-separated words)
- **When**: `bash wordstats.sh <fixture>` is run
- **Then**: exit code 0; the reported total word count is 11

### TOY-05: Unique word count is correct on the same fixture text
- **Surface**: cli (Bash)
- **Priority**: critical
- **Given**: the TOY-04 fixture (distinct words: the, quick, brown, fox, jumps, over, lazy, dog — 8 unique, case-insensitive)
- **When**: `bash wordstats.sh <fixture>` is run
- **Then**: exit code 0; the reported unique word count is 8

### TOY-06: Top-3 most frequent words are listed in descending frequency order
- **Surface**: cli (Bash)
- **Priority**: high
- **Given**: the TOY-04 fixture (`the` ×3, `fox` ×2, everything else ×1)
- **When**: `bash wordstats.sh <fixture>` is run
- **Then**: exit code 0; the top-words section lists `the` (count 3) first, `fox` (count 2) second, and a count-1 word third — counts non-increasing top to bottom

## Area: Edge cases

### TOY-07: An empty file yields zero counts and exit 0
- **Surface**: cli (Bash)
- **Priority**: high
- **Given**: an empty fixture file (created via `: > empty.txt`)
- **When**: `bash wordstats.sh empty.txt` is run
- **Then**: exit code 0; total word count reported as 0; unique word count reported as 0; no top-words entries

## Area: Test gate

### TOY-08: The repo's test runner passes end to end
- **Surface**: cli (Bash)
- **Priority**: critical
- **Given**: the repo root with `wordstats.sh` and `tests/wordstats_test.sh` present
- **When**: `bash tests/wordstats_test.sh` is run from the repo root
- **Then**: exit code 0; output shows per-case PASS lines and no FAIL lines
