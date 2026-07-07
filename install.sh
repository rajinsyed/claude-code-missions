#!/bin/bash
# install.sh — copies the kit payload into ~/.claude per architecture.md §3.
#
# Installed paths (exhaustive — nothing else is touched):
#   kit/agents/mission/       → ~/.claude/agents/mission/
#   kit/skills/mission-plan/  → ~/.claude/skills/mission-plan/
#   kit/skills/mission-run/   → ~/.claude/skills/mission-run/
#
# Every created path (files, then dirs) is written to
# ~/.claude/mission-kit-manifest.txt for exact reversal by uninstall.sh.
# Refuses to overwrite pre-existing destinations unless --force, in which
# case ONLY the kit's own destination paths above are replaced.
set -u

# Kit sources resolve from this script's own location — never $PWD.
KIT_ROOT="$(cd "$(dirname "$0")" && pwd)"
# Destination resolves from $HOME — never a hardcoded user path.
DEST="$HOME/.claude"
MANIFEST="$DEST/mission-kit-manifest.txt"

FORCE=0
for arg in "$@"; do
  case "$arg" in
    --force) FORCE=1 ;;
    *)
      echo "install.sh: unknown argument: $arg (only --force is supported)" >&2
      exit 1
      ;;
  esac
done

# Relative paths shared by source (under kit/) and destination (under ~/.claude).
REL_PATHS="agents/mission skills/mission-plan skills/mission-run"

# --- Preflight: determine which sources exist --------------------------------
# A missing source tree is skipped with a warning (the destination set never
# grows beyond the three contracted paths above).
INSTALL_PATHS=""
for rel in $REL_PATHS; do
  if [ -d "$KIT_ROOT/kit/$rel" ]; then
    INSTALL_PATHS="$INSTALL_PATHS $rel"
  else
    echo "install.sh: WARNING: kit source missing, skipping: $KIT_ROOT/kit/$rel" >&2
  fi
done
if [ -z "$INSTALL_PATHS" ]; then
  echo "install.sh: no kit sources found under $KIT_ROOT/kit — nothing to install" >&2
  exit 1
fi

# --- Conflict check BEFORE creating anything --------------------------------
# Without --force, any pre-existing destination aborts the install with
# nothing created (no files, no dirs, no manifest).
if [ "$FORCE" -eq 0 ]; then
  CONFLICT=0
  for rel in $INSTALL_PATHS; do
    if [ -e "$DEST/$rel" ]; then
      echo "install.sh: destination already exists: $DEST/$rel (use --force to replace)" >&2
      CONFLICT=1
    fi
  done
  if [ -e "$MANIFEST" ]; then
    echo "install.sh: destination already exists: $MANIFEST (use --force to replace)" >&2
    CONFLICT=1
  fi
  if [ "$CONFLICT" -ne 0 ]; then
    exit 1
  fi
else
  # --force replaces the kit's own paths ONLY. Nothing else is removed.
  for rel in $INSTALL_PATHS; do
    rm -rf "$DEST/$rel"
  done
  rm -f "$MANIFEST"
fi

# --- Copy, tracking every created path --------------------------------------
FILES_TMP="$(mktemp)"
DIRS_TMP="$(mktemp)"
LIST_TMP="$(mktemp)"
trap 'rm -f "$FILES_TMP" "$DIRS_TMP" "$LIST_TMP"' EXIT

# make_dir <abs-dir>: mkdir (one level) and record it if we created it.
make_dir() {
  if [ ! -d "$1" ]; then
    mkdir "$1" || exit 1
    echo "$1" >> "$DIRS_TMP"
  fi
}

# make_parents <abs-dir-under-DEST>: recursively create the chain from $DEST
# down to the given dir, recording every level we create — including $DEST
# itself on a pristine machine (so uninstall restores the truly-pristine
# state). Recursion keeps every path intact, whitespace and all.
make_parents() {
  case "$1" in
    "$DEST")
      if [ ! -d "$DEST" ]; then
        mkdir -p "$DEST" || exit 1
        echo "$DEST" >> "$DIRS_TMP"
      fi
      return 0
      ;;
    /|.)
      return 0
      ;;
  esac
  make_parents "$(dirname "$1")"
  make_dir "$1"
}

for rel in $INSTALL_PATHS; do
  SRC="$KIT_ROOT/kit/$rel"
  DST="$DEST/$rel"
  make_parents "$(dirname "$DST")"
  make_dir "$DST"
  # Recreate the source's directory structure, then copy each file. The while
  # loops read from a temp file — NOT a pipe — so they run in this shell and a
  # failed mkdir/cp aborts the whole install with a non-zero exit.
  find "$SRC" -type d | sort > "$LIST_TMP"
  while IFS= read -r d; do
    sub="${d#"$SRC"}"
    [ -n "$sub" ] || continue
    if [ ! -d "$DST$sub" ]; then
      mkdir "$DST$sub" || { echo "install.sh: ERROR: mkdir failed: $DST$sub — aborting" >&2; exit 1; }
      echo "$DST$sub" >> "$DIRS_TMP"
    fi
  done < "$LIST_TMP"
  find "$SRC" -type f | sort > "$LIST_TMP"
  while IFS= read -r f; do
    sub="${f#"$SRC"}"
    cp "$f" "$DST$sub" || { echo "install.sh: ERROR: cp failed: $f -> $DST$sub — aborting" >&2; exit 1; }
    echo "$DST$sub" >> "$FILES_TMP"
  done < "$LIST_TMP"
done

# --- Hook scripts must be executable ----------------------------------------
for hook in guard-mission-state.sh require-handoff.sh; do
  HP="$DEST/agents/mission/hooks/$hook"
  if [ -f "$HP" ]; then
    chmod +x "$HP" || exit 1
  fi
done

# --- Write manifest: files first, then dirs (deepest-first), no duplicates ---
# The manifest lists itself too (it is a created path); uninstall.sh removes
# it last regardless.
echo "$MANIFEST" >> "$FILES_TMP"
{
  sort -u "$FILES_TMP"
  sort -ur "$DIRS_TMP"
} > "$MANIFEST"

echo "install.sh: installed mission kit into $DEST (manifest: $MANIFEST)"
exit 0
