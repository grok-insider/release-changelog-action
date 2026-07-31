#!/usr/bin/env bash
#
# publish-github-release.sh — set a GitHub Release body from a notes file.
#
# Usage:
#   publish-github-release.sh <tag> <notes-file>
#
# Environment:
#   GITHUB_TOKEN / GH_TOKEN  required for gh
#   GH_REPO                  optional owner/name (else gh uses current repo)
#   RELEASE_TITLE            optional (default: tag)
#   CREATE_IF_MISSING        true (default) | false
#   PUBLISH_RESULT_FILE      optional path; written true|false

set -euo pipefail

tag="${1:?usage: publish-github-release.sh <tag> <notes-file>}"
notes_file="${2:?usage: publish-github-release.sh <tag> <notes-file>}"
title="${RELEASE_TITLE:-$tag}"
create_if_missing="${CREATE_IF_MISSING:-true}"
result_file="${PUBLISH_RESULT_FILE:-}"

write_result() {
  if [ -n "$result_file" ]; then
    printf '%s\n' "$1" > "$result_file"
  fi
}

if [ ! -s "$notes_file" ]; then
  echo "::warning::Notes file is empty; not publishing GitHub Release body"
  write_result false
  exit 0
fi

if ! command -v gh >/dev/null 2>&1; then
  echo "::error::gh CLI is required to publish GitHub Release notes"
  write_result false
  exit 1
fi

if [ -z "${GITHUB_TOKEN:-${GH_TOKEN:-}}" ]; then
  echo "::error::GITHUB_TOKEN or GH_TOKEN is required to publish GitHub Release notes"
  write_result false
  exit 1
fi

# Prefer GH_TOKEN for gh when only GITHUB_TOKEN is set.
export GH_TOKEN="${GH_TOKEN:-$GITHUB_TOKEN}"

repo_args=()
if [ -n "${GH_REPO:-}" ]; then
  repo_args=(-R "$GH_REPO")
fi

if gh release view "$tag" "${repo_args[@]}" >/dev/null 2>&1; then
  gh release edit "$tag" "${repo_args[@]}" --notes-file "$notes_file" --title "$title"
  echo "Updated GitHub Release $tag notes"
  write_result true
  exit 0
fi

if [ "$create_if_missing" = "true" ]; then
  gh release create "$tag" "${repo_args[@]}" --title "$title" --notes-file "$notes_file"
  echo "Created GitHub Release $tag with notes"
  write_result true
  exit 0
fi

echo "::warning::Release $tag does not exist and create-if-missing is false"
write_result false
