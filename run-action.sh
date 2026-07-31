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
skip_generate="${SKIP_GENERATE:-false}"
publish_github_release="${PUBLISH_GITHUB_RELEASE:-false}"
github_token="${GITHUB_TOKEN_INPUT:-}"
release_tag="${RELEASE_TAG:-}"
notes_footer="${NOTES_FOOTER:-}"
notes_footer_file="${NOTES_FOOTER_FILE:-}"
release_title="${RELEASE_TITLE:-}"
create_if_missing="${CREATE_IF_MISSING:-true}"

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
case "$skip_generate" in
  true|false) ;;
  *) echo "::error::Unsupported skip-generate: $skip_generate"; exit 2 ;;
esac
case "$publish_github_release" in
  true|false) ;;
  *) echo "::error::Unsupported publish-github-release: $publish_github_release"; exit 2 ;;
esac

if [ "$skip_generate" = "true" ] && [ "$publish_github_release" != "true" ]; then
  echo "::error::skip-generate requires publish-github-release=true"
  exit 2
fi

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
notes_file="$(mktemp)"
publish_result_file="$(mktemp)"
# section_file is kept for later workflow steps; notes_file only when published.
trap 'rm -f "$before_file" "$generation_source_file" "$update_result_file" "$publish_result_file"; if [ "${published_keep_notes:-false}" != true ]; then rm -f "$notes_file"; fi' EXIT

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
  local changed="$1" generation_source="$2" published="$3"
  {
    echo "section-file=$section_file"
    echo "changed=$changed"
    echo "generation-source=$generation_source"
    echo "notes-file=$notes_file"
    echo "published=$published"
  } >> "$github_output"
}

build_notes_file() {
  local body
  body="$(bash "$root/extract-section.sh" "$version" "$changelog_file")"
  if [ -z "$body" ]; then
    # Prefer generated section body (strip heading) when CHANGELOG has no section.
    if [ -s "$section_file" ]; then
      body="$(awk 'BEGIN{skip=1} /^##[ \t]+/ && skip{skip=0; next} {print}' "$section_file")"
    fi
  fi
  {
    if [ -n "$body" ]; then
      printf '%s\n' "$body"
    fi
    if [ -n "$notes_footer_file" ]; then
      if [ ! -f "$notes_footer_file" ]; then
        echo "::error::notes-footer-file not found: $notes_footer_file"
        exit 1
      fi
      if [ -n "$body" ]; then
        printf '\n'
      fi
      cat "$notes_footer_file"
      printf '\n'
    elif [ -n "$notes_footer" ]; then
      if [ -n "$body" ]; then
        printf '\n'
      fi
      # Expand literal \n sequences from composite action multiline quirks is not needed;
      # GitHub Actions passes real newlines in env for multiline values when using |.
      printf '%s\n' "$notes_footer"
    fi
  } > "$notes_file"
}

publish_if_requested() {
  if [ "$publish_github_release" != "true" ]; then
    printf 'false\n' > "$publish_result_file"
    return 0
  fi
  if [ -z "$release_tag" ]; then
    release_tag="v${version}"
  fi
  if [ -z "$github_token" ]; then
    echo "::error::github-token is required when publish-github-release=true"
    exit 1
  fi
  build_notes_file
  if [ ! -s "$notes_file" ]; then
    echo "::warning::No release notes body for v$version; skip publish"
    printf 'false\n' > "$publish_result_file"
    return 0
  fi
  echo "::group::GitHub Release notes for $release_tag"
  cat "$notes_file"
  echo "::endgroup::"
  export GITHUB_TOKEN="$github_token"
  export GH_TOKEN="$github_token"
  export CREATE_IF_MISSING="$create_if_missing"
  export PUBLISH_RESULT_FILE="$publish_result_file"
  if [ -n "$release_title" ]; then
    export RELEASE_TITLE="$release_title"
  else
    export RELEASE_TITLE="$release_tag"
  fi
  bash "$root/publish-github-release.sh" "$release_tag" "$notes_file"
}

generation_source=preserved
changed=false

if [ "$skip_generate" = "true" ]; then
  : > "$section_file"
  printf 'preserved\n' > "$generation_source_file"
  generation_source=preserved
  echo "skip-generate=true; publishing from existing $changelog_file only"
elif [ "$update_mode" = "highlights" ] && ! has_version_section; then
  : > "$section_file"
  printf 'preserved\n' > "$generation_source_file"
  generation_source=preserved
  echo "::warning::No existing v$version section was found; preserving $changelog_file"
else
  export UPDATE_MODE="$update_mode"
  export FALLBACK_MODE="$fallback_mode"
  export COMMIT_DETAIL="$commit_detail"
  export GENERATION_SOURCE_FILE="$generation_source_file"
  export UPDATE_RESULT_FILE="$update_result_file"

  echo "Generating changelog for v$version over range: $range (update-mode=$update_mode, fallback-mode=$fallback_mode, commit-detail=$commit_detail, model=${CHANGELOG_MODEL:-default})"
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
    echo "::group::Generated changelog section (source=$generation_source)"
    cat "$section_file"
    echo "::endgroup::"
    if [ "$generation_source" = "fallback" ]; then
      echo "::warning::Used commit-list fallback (not AI prose). Check OpenRouter key/model/logs."
    fi
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
fi

publish_if_requested
published="$(cat "$publish_result_file" 2>/dev/null || echo false)"
if [ "$published" = "true" ]; then
  published_keep_notes=true
fi
echo "generation-source=$generation_source changed=$changed published=$published"
write_outputs "$changed" "$generation_source" "$published"
