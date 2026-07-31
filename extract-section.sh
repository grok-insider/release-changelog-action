#!/usr/bin/env bash
#
# extract-section.sh — print the body of one CHANGELOG version section (no heading).
#
# Usage:
#   extract-section.sh <version> [<changelog-file>]
#
# Matches Keep a Changelog (`## [0.1.1] - date`), plain (`## 0.1.1`), or linked
# headings. Exits 0 with empty stdout if no section is found.

set -euo pipefail

version="${1:?usage: extract-section.sh <version> [<changelog-file>]}"
changelog_file="${2:-CHANGELOG.md}"

if [ ! -f "$changelog_file" ]; then
  exit 0
fi

awk -v version="$version" '
  function hver(line,   value) {
    value = line
    sub(/^##+[ \t]+/, "", value)
    sub(/^\[/, "", value)
    sub(/\].*/, "", value)
    sub(/[ \t].*/, "", value)
    sub(/\r$/, "", value)
    return value
  }
  /^##[ \t]+/ {
    if (found) exit
    if (hver($0) == version) {
      found = 1
      next
    }
  }
  found { print }
' "$changelog_file"
