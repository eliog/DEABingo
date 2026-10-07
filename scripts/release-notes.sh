#!/bin/sh
# Prints the top section of CHANGELOG.md (the newest release) for use as
# GitHub release notes, so a release page never repeats the whole history.
# Usage: scripts/release-notes.sh [CHANGELOG.md]
set -e
file="${1:-$(dirname "$0")/../CHANGELOG.md}"
awk '
  /^## / { if (started) exit; started = 1 }
  started { print }
' "$file" | sed -e '1{/^$/d;}' -e '${/^$/d;}'
