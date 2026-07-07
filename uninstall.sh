#!/bin/bash
# uninstall.sh — removes exactly the paths listed in
# ~/.claude/mission-kit-manifest.txt (files first, then dirs only if empty),
# then removes the manifest itself. Exits non-zero, touching nothing, if the
# manifest is missing. Never removes a non-empty directory it did not fully
# own, and never touches any path outside ~/.claude.
set -u

DEST="$HOME/.claude"
MANIFEST="$DEST/mission-kit-manifest.txt"

if [ ! -f "$MANIFEST" ]; then
  echo "uninstall.sh: manifest not found: $MANIFEST — nothing to remove (was the kit installed?)" >&2
  exit 1
fi

# Pass 1: remove files (and symlinks). Only paths inside ~/.claude are honored.
while IFS= read -r p; do
  [ -n "$p" ] || continue
  case "$p" in
    "$DEST") continue ;; # ~/.claude itself is a dir — handled after pass 2
    "$DEST"/*) : ;;
    *) echo "uninstall.sh: skipping manifest entry outside $DEST: $p" >&2; continue ;;
  esac
  [ "$p" = "$MANIFEST" ] && continue
  if [ -f "$p" ] || [ -L "$p" ]; then
    rm -f "$p"
  fi
done < "$MANIFEST"

# If install.sh created ~/.claude itself (pristine machine), the manifest
# records $DEST too; note that BEFORE the manifest is deleted below.
DEST_LISTED=0
if grep -qxF "$DEST" "$MANIFEST"; then
  DEST_LISTED=1
fi

# Pass 2: remove directories, deepest first, only if now empty.
# $DEST itself is deferred: the manifest still lives inside it.
sort -r "$MANIFEST" | while IFS= read -r p; do
  [ -n "$p" ] || continue
  case "$p" in
    "$DEST"/*) : ;;
    *) continue ;;
  esac
  if [ -d "$p" ]; then
    rmdir "$p" 2>/dev/null || true
  fi
done

# The manifest itself is removed last (of the files we own).
rm -f "$MANIFEST"

# Finally, if we created ~/.claude itself, remove it — only if now empty.
if [ "$DEST_LISTED" -eq 1 ] && [ -d "$DEST" ]; then
  rmdir "$DEST" 2>/dev/null || true
fi

echo "uninstall.sh: mission kit removed from $DEST"
exit 0
