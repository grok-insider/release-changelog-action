#!/usr/bin/env bash

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
version="${VERSION:?VERSION is required}"
range="${RANGE:-}"
update_mode="${UPDATE_MODE:-replace-section}"
fallback_mode="${FALLBACK_MODE:-commit-list}"
commit_detail="${COMMIT_DETAIL:-full}"
changelog_file="${CHANGELOG_FILE:-CHANGELOG.md}"
github_output="${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"

case "$update_mode" in
  replace-section|highlights) ;;
  *) echo "::error::Unsupported update-mode: $update_mode"; exit 2 ;;
esac
case "$fallback_mode" in
  commit-list|preserve) ;;
  *) echo "::error::Unsupported fallback-mode: $fallback_mode"; exit 2 ;;
esac
case "$commit_detail" in
  full|subjects) ;;
  *) echo "::error::Unsupported commit-detail: $commit_detail"; exit 2 ;;
esac

if [ -z "$range" ]; then
  prev_tag="$(git tag -l 'v[0-9]*' --sort=-v:refname | head -n1 || true)"
  if [ -z "$prev_tag" ]; then
    prev_tag="$(git describe --tags --abbrev=0 HEAD 2>/dev/null || true)"
  fi
  if [ -n "$prev_tag" ]; then range="${prev_tag}..HEAD"; else range="HEAD"; fi
fi

before_file="$(mktemp)"
generation_source_file="$(mktemp)"
update_result_file="$(mktemp)"
section_file="$(mktemp)"
trap 'rm -f "$before_file" "$generation_source_file" "$update_result_file"' EXIT

if [ -f "$changelog_file" ]; then
  cp "$changelog_file" "$before_file"
  changelog_existed=true
else
  changelog_existed=false
fi

has_version_section() {
  [ -f "$changelog_file" ] || return 1
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
    /^##[ \t]+/ && hver($0) == version { found = 1; exit }
    END { exit found ? 0 : 1 }
  ' "$changelog_file"
}

write_outputs() {
  local changed="$1" generation_source="$2"
  {
    echo "section-file=$section_file"
    echo "changed=$changed"
    echo "generation-source=$generation_source"
  } >> "$github_output"
}

if [ "$update_mode" = "highlights" ] && ! has_version_section; then
  echo "::warning::No existing v$version section was found; preserving $changelog_file"
  write_outputs false preserved
  exit 0
fi

export UPDATE_MODE="$update_mode"
export FALLBACK_MODE="$fallback_mode"
export COMMIT_DETAIL="$commit_detail"
export GENERATION_SOURCE_FILE="$generation_source_file"
export UPDATE_RESULT_FILE="$update_result_file"

echo "Generating changelog for v$version over range: $range (update-mode=$update_mode, fallback-mode=$fallback_mode, commit-detail=$commit_detail)"
if ! bash "$root/gen-changelog.sh" "$version" "$range" > "$section_file"; then
  if [ "$fallback_mode" = "preserve" ]; then
    : > "$section_file"
    printf 'preserved\n' > "$generation_source_file"
  else
    echo "::error::Changelog generation failed before producing a fallback"
    exit 1
  fi
fi

generation_source="$(cat "$generation_source_file")"
case "$generation_source" in
  ai|fallback|preserved) ;;
  *)
    if [ "$fallback_mode" = "preserve" ]; then
      generation_source=preserved
      : > "$section_file"
    else
      echo "::error::Changelog generation did not report a valid source"
      exit 1
    fi
    ;;
esac

if [ "$generation_source" = "preserved" ]; then
  echo "::warning::Changelog generation was unavailable; preserving $changelog_file"
else
  echo "::group::Generated changelog section"
  cat "$section_file"
  echo "::endgroup::"
  bash "$root/update-changelog.sh" "$version" "$section_file"
  if [ "$(cat "$update_result_file")" = "preserved" ]; then
    generation_source=preserved
    echo "::warning::No existing v$version section was found; preserving $changelog_file"
  fi
fi

if [ "$changelog_existed" = true ] && [ -f "$changelog_file" ] && cmp -s "$before_file" "$changelog_file"; then
  changed=false
elif [ "$changelog_existed" = false ] && [ ! -f "$changelog_file" ]; then
  changed=false
else
  changed=true
fi

write_outputs "$changed" "$generation_source"
