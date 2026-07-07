#!/bin/bash
# tests/test-installer.sh — validates install.sh / uninstall.sh, assertions
# INS-01..INS-10.
#
# CRITICAL SAFETY: every case runs against a sandboxed fake home created with
# mktemp -d. HOME is exported to the sandbox and asserted to be inside the
# mktemp area (and NOT inside the real home) BEFORE any install step. The real
# ~/.claude is NEVER touched by this script.
set -u

KIT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL="$KIT_ROOT/install.sh"
UNINSTALL="$KIT_ROOT/uninstall.sh"
STATUS=0
REAL_HOME="$HOME"

# Scratch dir for snapshots and captured stderr (NOT a fake home).
WORK="$(mktemp -d)"
# The machine's real mktemp area — every sandbox must live inside it.
TMP_BASE="$(dirname "$WORK")"
SANDBOXES="$WORK"

note() { echo "  $*" >&2; }

result() {
  # result <ASSERTION-ID> <0|nonzero>
  if [ "$2" -eq 0 ]; then
    echo "PASS $1"
  else
    echo "FAIL $1"
    STATUS=1
  fi
}

# ---------------------------------------------------------------------------
# Sandbox helpers
# ---------------------------------------------------------------------------

new_sandbox() {
  # Creates a fresh fake home, exports HOME to it, and HARD-FAILS the whole
  # test run if the sandbox is not safely inside the mktemp area. These
  # assertions run BEFORE any install step, per the contract.
  SANDBOX="$(mktemp -d)"
  case "$SANDBOX" in
    "$TMP_BASE"/*) : ;; # inside the mktemp sandbox area — OK
    *)
      echo "FATAL: sandbox $SANDBOX is not inside mktemp area $TMP_BASE — refusing to run installer tests" >&2
      exit 1
      ;;
  esac
  case "$SANDBOX" in
    "$REAL_HOME"|"$REAL_HOME"/*)
      echo "FATAL: sandbox $SANDBOX is inside the real home $REAL_HOME — refusing" >&2
      exit 1
      ;;
  esac
  export HOME="$SANDBOX"
  if [ "$HOME" = "$REAL_HOME" ]; then
    echo "FATAL: HOME still resolves to the real home $REAL_HOME — refusing" >&2
    exit 1
  fi
  SANDBOXES="$SANDBOXES $SANDBOX"
  MANIFEST="$HOME/.claude/mission-kit-manifest.txt"
}

seed_decoys() {
  # Decoy user content that must survive install/uninstall untouched.
  # An empty agents/ dir is seeded too — it mirrors the real ~/.claude
  # (library/environment.md: agents/ exists and is empty at mission start).
  mkdir -p "$HOME/.claude/skills/existing-skill" "$HOME/.claude/agents"
  printf '{"decoy": "settings", "defaultMode": "acceptEdits"}\n' > "$HOME/.claude/settings.json"
  printf '# Decoy CLAUDE.md\nUser global instructions that must survive.\n' > "$HOME/.claude/CLAUDE.md"
  printf -- '---\nname: existing-skill\ndescription: decoy skill\n---\nDecoy skill body.\n' \
    > "$HOME/.claude/skills/existing-skill/SKILL.md"
}

snap() { find "$HOME/.claude" | sort; }

decoy_shasums() {
  ( cd "$HOME/.claude" && shasum settings.json CLAUDE.md skills/existing-skill/SKILL.md )
}

tree_checksums() {
  # Checksums of every file in the three installed trees.
  ( cd "$HOME/.claude" && \
    find agents/mission skills/mission-plan skills/mission-run -type f 2>/dev/null | sort | \
    while IFS= read -r f; do shasum "$f"; done )
}

cleanup() {
  export HOME="$REAL_HOME"
  for d in $SANDBOXES; do
    case "$d" in
      "$TMP_BASE"/*) rm -rf "$d" ;;
    esac
  done
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Prerequisites: both scripts must exist at the kit repo root
# ---------------------------------------------------------------------------
if [ ! -f "$INSTALL" ] || [ ! -f "$UNINSTALL" ]; then
  note "install.sh and/or uninstall.sh missing at kit repo root ($KIT_ROOT)"
  for id in INS-01 INS-02 INS-03 INS-04 INS-05 INS-06 INS-07; do
    result "$id" 1
  done
  exit "$STATUS"
fi

# ---------------------------------------------------------------------------
# Sandbox 1 — INS-01 (clean install), INS-07 (hook exec bits),
#             INS-03 (idempotent --force reinstall)
# ---------------------------------------------------------------------------
new_sandbox
seed_decoys
snap > "$WORK/before.txt"

( cd "$KIT_ROOT" && ./install.sh ) > "$WORK/ins01.out" 2> "$WORK/ins01.err"
rc=$?
snap > "$WORK/after.txt"

# --- INS-01: install copies exactly the three namespaced trees + manifest ---
ins01=0
if [ "$rc" -ne 0 ]; then
  note "INS-01: install.sh exited $rc (stderr: $(cat "$WORK/ins01.err"))"
  ins01=1
fi
comm -23 "$WORK/before.txt" "$WORK/after.txt" > "$WORK/removed.txt"
if [ -s "$WORK/removed.txt" ]; then
  note "INS-01: install removed pre-existing paths: $(tr '\n' ' ' < "$WORK/removed.txt")"
  ins01=1
fi
comm -13 "$WORK/before.txt" "$WORK/after.txt" > "$WORK/added.txt"
if [ ! -s "$WORK/added.txt" ]; then
  note "INS-01: install added no paths at all"
  ins01=1
fi
if [ ! -f "$MANIFEST" ]; then
  note "INS-01: manifest $MANIFEST was not written"
  ins01=1
fi
while IFS= read -r p; do
  case "$p" in
    "$HOME/.claude/agents/mission"|"$HOME/.claude/agents/mission/"*) : ;;
    "$HOME/.claude/skills/mission-plan"|"$HOME/.claude/skills/mission-plan/"*) : ;;
    "$HOME/.claude/skills/mission-run"|"$HOME/.claude/skills/mission-run/"*) : ;;
    "$MANIFEST") : ;;
    *) note "INS-01: unexpected added path outside the allowed trees: $p"; ins01=1 ;;
  esac
  if ! grep -qxF "$p" "$MANIFEST" 2>/dev/null; then
    note "INS-01: added path not listed in manifest: $p"
    ins01=1
  fi
done < "$WORK/added.txt"
if ! grep -qF "$HOME/.claude/agents/mission/" "$WORK/added.txt"; then
  note "INS-01: agents/mission tree was not installed"
  ins01=1
fi
result INS-01 "$ins01"

# --- INS-07: hook scripts installed with executable bit ---
ins07=0
for h in guard-mission-state.sh require-handoff.sh; do
  hp="$HOME/.claude/agents/mission/hooks/$h"
  if [ ! -f "$hp" ]; then
    note "INS-07: $hp does not exist"
    ins07=1
    continue
  fi
  if [ ! -x "$hp" ]; then
    note "INS-07: $hp is not executable"
    ins07=1
  fi
  err="$(printf '' | "$hp" 2>&1 >/dev/null)"
  hrc=$?
  if [ "$hrc" -eq 126 ] || echo "$err" | grep -qi "permission denied"; then
    note "INS-07: executing $hp failed with permission denied (rc=$hrc)"
    ins07=1
  fi
done
result INS-07 "$ins07"

# --- INS-03: reinstall with --force is idempotent ---
snap > "$WORK/after1.txt"
tree_checksums > "$WORK/sums1.txt"
( cd "$KIT_ROOT" && ./install.sh --force ) > /dev/null 2> "$WORK/ins03.err"
rc=$?
snap > "$WORK/after2.txt"
tree_checksums > "$WORK/sums2.txt"
ins03=0
if [ "$rc" -ne 0 ]; then
  note "INS-03: install.sh --force exited $rc (stderr: $(cat "$WORK/ins03.err"))"
  ins03=1
fi
if ! diff "$WORK/after1.txt" "$WORK/after2.txt" > /dev/null; then
  note "INS-03: find snapshots differ between first install and --force reinstall"
  ins03=1
fi
if ! diff "$WORK/sums1.txt" "$WORK/sums2.txt" > /dev/null; then
  note "INS-03: installed-tree checksums differ after --force reinstall"
  ins03=1
fi
if [ ! -s "$MANIFEST" ]; then
  note "INS-03: manifest missing or empty after --force reinstall"
  ins03=1
else
  dups="$(sort "$MANIFEST" | uniq -d)"
  if [ -n "$dups" ]; then
    note "INS-03: manifest contains duplicate lines: $dups"
    ins03=1
  fi
fi
result INS-03 "$ins03"

# ---------------------------------------------------------------------------
# Sandbox 2 — INS-02 (refuses to overwrite pre-existing destination, no --force)
# ---------------------------------------------------------------------------
new_sandbox
seed_decoys
mkdir -p "$HOME/.claude/agents/mission"
printf 'sentinel: pre-existing user content, do not overwrite\n' \
  > "$HOME/.claude/agents/mission/PREEXISTING.md"
sen_before="$(shasum "$HOME/.claude/agents/mission/PREEXISTING.md")"
snap > "$WORK/pre02.txt"

( cd "$KIT_ROOT" && ./install.sh ) > /dev/null 2> "$WORK/ins02.err"
rc=$?
snap > "$WORK/post02.txt"

ins02=0
if [ "$rc" -eq 0 ]; then
  note "INS-02: install without --force exited 0 despite pre-existing agents/mission"
  ins02=1
fi
if ! grep -qF "$HOME/.claude/agents/mission" "$WORK/ins02.err"; then
  note "INS-02: stderr does not name the conflicting path (stderr: $(cat "$WORK/ins02.err"))"
  ins02=1
fi
if ! diff "$WORK/pre02.txt" "$WORK/post02.txt" > /dev/null; then
  note "INS-02: refused install still changed the filesystem"
  ins02=1
fi
if [ -e "$MANIFEST" ]; then
  note "INS-02: manifest was created despite refusal"
  ins02=1
fi
sen_after="$(shasum "$HOME/.claude/agents/mission/PREEXISTING.md")"
if [ "$sen_before" != "$sen_after" ]; then
  note "INS-02: sentinel content changed"
  ins02=1
fi
result INS-02 "$ins02"

# ---------------------------------------------------------------------------
# Sandbox 3 — INS-04 (uninstall restores before-install snapshot),
#             INS-06 (decoys survive the full round-trip)
# ---------------------------------------------------------------------------
new_sandbox
seed_decoys
decoy_shasums > "$WORK/decoys_before.txt"
( cd "$HOME/.claude/skills/existing-skill" && ls -1 | sort ) > "$WORK/skill_entries_before.txt"
snap > "$WORK/before3.txt"

( cd "$KIT_ROOT" && ./install.sh ) > /dev/null 2> "$WORK/ins04-install.err"
rc_install=$?
decoy_shasums > "$WORK/decoys_mid.txt"

( cd "$KIT_ROOT" && ./uninstall.sh ) > /dev/null 2> "$WORK/ins04-uninstall.err"
rc_uninstall=$?
snap > "$WORK/restored.txt"
decoy_shasums > "$WORK/decoys_after.txt"
( cd "$HOME/.claude/skills/existing-skill" && ls -1 | sort ) > "$WORK/skill_entries_after.txt"

ins04=0
if [ "$rc_install" -ne 0 ]; then
  note "INS-04: precondition install exited $rc_install"
  ins04=1
fi
if [ "$rc_uninstall" -ne 0 ]; then
  note "INS-04: uninstall.sh exited $rc_uninstall (stderr: $(cat "$WORK/ins04-uninstall.err"))"
  ins04=1
fi
if ! diff "$WORK/before3.txt" "$WORK/restored.txt" > /dev/null; then
  note "INS-04: post-uninstall snapshot differs from pre-install snapshot:"
  diff "$WORK/before3.txt" "$WORK/restored.txt" >&2 || true
  ins04=1
fi
if [ -e "$MANIFEST" ]; then
  note "INS-04: manifest still present after uninstall"
  ins04=1
fi
result INS-04 "$ins04"

ins06=0
if ! diff "$WORK/decoys_before.txt" "$WORK/decoys_mid.txt" > /dev/null; then
  note "INS-06: decoy checksums changed after install"
  ins06=1
fi
if ! diff "$WORK/decoys_before.txt" "$WORK/decoys_after.txt" > /dev/null; then
  note "INS-06: decoy checksums changed after uninstall"
  ins06=1
fi
if ! diff "$WORK/skill_entries_before.txt" "$WORK/skill_entries_after.txt" > /dev/null; then
  note "INS-06: skills/existing-skill entries changed across the round-trip"
  ins06=1
fi
result INS-06 "$ins06"

# ---------------------------------------------------------------------------
# Sandbox 4 — INS-08 (whitespace robustness: HOME containing a space)
# Polish sub-case from milestone-1 scrutiny (not a contract ID): the full
# install + uninstall round-trip must work when $HOME contains a space.
# ---------------------------------------------------------------------------
new_sandbox
mkdir "$SANDBOX/home with space"
export HOME="$SANDBOX/home with space"
MANIFEST="$HOME/.claude/mission-kit-manifest.txt"
seed_decoys
snap > "$WORK/before8.txt"

( cd "$KIT_ROOT" && ./install.sh ) > /dev/null 2> "$WORK/ins08.err"
rc_install=$?

ins08=0
if [ "$rc_install" -ne 0 ]; then
  note "INS-08: install.sh exited $rc_install with whitespace HOME (stderr: $(cat "$WORK/ins08.err"))"
  ins08=1
fi
for p in "$HOME/.claude/agents/mission" "$HOME/.claude/skills/mission-plan" \
         "$HOME/.claude/skills/mission-run" "$MANIFEST"; do
  if [ ! -e "$p" ]; then
    note "INS-08: expected installed path missing under whitespace HOME: $p"
    ins08=1
  fi
done
for h in guard-mission-state.sh require-handoff.sh; do
  if [ ! -x "$HOME/.claude/agents/mission/hooks/$h" ]; then
    note "INS-08: hook not installed executable under whitespace HOME: $h"
    ins08=1
  fi
done

( cd "$KIT_ROOT" && ./uninstall.sh ) > /dev/null 2> "$WORK/ins08-un.err"
rc_uninstall=$?
if [ "$rc_uninstall" -ne 0 ]; then
  note "INS-08: uninstall.sh exited $rc_uninstall with whitespace HOME (stderr: $(cat "$WORK/ins08-un.err"))"
  ins08=1
fi
snap > "$WORK/after8.txt"
if ! diff "$WORK/before8.txt" "$WORK/after8.txt" > /dev/null; then
  note "INS-08: post-uninstall snapshot differs from pre-install snapshot under whitespace HOME:"
  diff "$WORK/before8.txt" "$WORK/after8.txt" >&2 || true
  ins08=1
fi
result INS-08 "$ins08"

# ---------------------------------------------------------------------------
# Sandbox 5 — INS-09 (pristine home: NO ~/.claude at all before install)
# Polish sub-case from milestone-1 scrutiny (not a contract ID): install must
# record ~/.claude itself in the manifest when it creates it, so uninstall
# restores the truly-pristine state (no ~/.claude left behind).
# ---------------------------------------------------------------------------
new_sandbox
# Deliberately NO seed_decoys and NO mkdir: $HOME has no .claude at all.
( find "$HOME" | sort ) > "$WORK/before9.txt"

( cd "$KIT_ROOT" && ./install.sh ) > /dev/null 2> "$WORK/ins09.err"
rc_install=$?

ins09=0
if [ "$rc_install" -ne 0 ]; then
  note "INS-09: install.sh exited $rc_install on pristine home (stderr: $(cat "$WORK/ins09.err"))"
  ins09=1
fi
if [ ! -f "$MANIFEST" ]; then
  note "INS-09: manifest $MANIFEST was not written"
  ins09=1
elif ! grep -qxF "$HOME/.claude" "$MANIFEST"; then
  note "INS-09: manifest does not record the created $HOME/.claude itself"
  ins09=1
fi

( cd "$KIT_ROOT" && ./uninstall.sh ) > /dev/null 2> "$WORK/ins09-un.err"
rc_uninstall=$?
if [ "$rc_uninstall" -ne 0 ]; then
  note "INS-09: uninstall.sh exited $rc_uninstall (stderr: $(cat "$WORK/ins09-un.err"))"
  ins09=1
fi
if [ -e "$HOME/.claude" ]; then
  note "INS-09: $HOME/.claude still exists after uninstall on a pristine home"
  ins09=1
fi
( find "$HOME" | sort ) > "$WORK/after9.txt"
if ! diff "$WORK/before9.txt" "$WORK/after9.txt" > /dev/null; then
  note "INS-09: post-uninstall home differs from the truly-pristine state:"
  diff "$WORK/before9.txt" "$WORK/after9.txt" >&2 || true
  ins09=1
fi
result INS-09 "$ins09"

# ---------------------------------------------------------------------------
# Sandbox 6 — INS-10 (a failed cp during the copy loop aborts the install
# with a non-zero exit — no swallowed subshell errors).
# Polish sub-case from milestone-1 scrutiny (not a contract ID). Uses a
# throwaway copy of the kit with one unreadable payload file so cp fails.
# ---------------------------------------------------------------------------
new_sandbox
seed_decoys

TMPKIT="$WORK/brokenkit"
mkdir -p "$TMPKIT"
cp "$KIT_ROOT/install.sh" "$TMPKIT/install.sh"
cp -R "$KIT_ROOT/kit" "$TMPKIT/kit"
BADF="$(find "$TMPKIT/kit/agents/mission" -type f | sort | head -n 1)"

ins10=0
if [ -z "$BADF" ]; then
  note "INS-10: could not find a payload file to make unreadable"
  ins10=1
else
  chmod 000 "$BADF"
  ( cd "$TMPKIT" && ./install.sh ) > /dev/null 2> "$WORK/ins10.err"
  rc=$?
  chmod 644 "$BADF"
  if [ "$rc" -eq 0 ]; then
    note "INS-10: install.sh exited 0 despite a failed cp (unreadable $BADF)"
    ins10=1
  fi
fi
result INS-10 "$ins10"

# ---------------------------------------------------------------------------
# Sandbox 7 — INS-05 (uninstall with missing manifest fails cleanly)
# ---------------------------------------------------------------------------
new_sandbox
seed_decoys
snap > "$WORK/pre05.txt"

( cd "$KIT_ROOT" && ./uninstall.sh ) > /dev/null 2> "$WORK/ins05.err"
rc=$?
snap > "$WORK/post05.txt"

ins05=0
if [ "$rc" -eq 0 ]; then
  note "INS-05: uninstall exited 0 despite missing manifest"
  ins05=1
fi
if ! grep -qi "manifest" "$WORK/ins05.err"; then
  note "INS-05: stderr does not reference the missing manifest (stderr: $(cat "$WORK/ins05.err"))"
  ins05=1
fi
if ! diff "$WORK/pre05.txt" "$WORK/post05.txt" > /dev/null; then
  note "INS-05: uninstall with missing manifest changed the filesystem"
  ins05=1
fi
result INS-05 "$ins05"

exit "$STATUS"
