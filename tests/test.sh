#!/usr/bin/env bash

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
tests=0

fail() {
  echo "not ok - $1" >&2
  exit 1
}

pass() {
  tests=$((tests + 1))
  echo "ok $tests - $1"
}

assert_file_equals() {
  local expected="$1" actual="$2" message="$3"
  if ! cmp -s "$expected" "$actual"; then
    diff -u "$expected" "$actual" >&2 || true
    fail "$message"
  fi
}

assert_equals() {
  local expected="$1" actual="$2" message="$3"
  if [ "$expected" != "$actual" ]; then
    printf 'expected: %q\nactual:   %q\n' "$expected" "$actual" >&2
    fail "$message"
  fi
}

output_value() {
  local name="$1" file="$2"
  sed -n "s/^${name}=//p" "$file" | tail -n1
}

repo="$tmp/repo"
mkdir -p "$repo" "$tmp/bin"
cp "$root/tests/fake-curl.sh" "$tmp/bin/curl"
chmod 0755 "$tmp/bin/curl"
git -C "$repo" init -q
git -C "$repo" config user.name Test
git -C "$repo" config user.email test@example.com
printf 'one\n' > "$repo/file.txt"
git -C "$repo" add file.txt
git -C "$repo" commit -q -m 'Added first capability' -m 'SECRET_BODY_SENTINEL'
printf 'two\n' >> "$repo/file.txt"
git -C "$repo" commit -qam 'fix: second capability'

source_file="$tmp/source"
output="$tmp/output"
(
  cd "$repo"
  HEADING_DATE=2026-07-10 GENERATION_SOURCE_FILE="$source_file" \
    bash "$root/gen-changelog.sh" 1.2.0 HEAD > "$output"
)
cat > "$tmp/expected" <<'EOF'
## [1.2.0] - 2026-07-10

- fix: second capability
- Added first capability
EOF
assert_file_equals "$tmp/expected" "$output" "default fallback output changed"
assert_equals fallback "$(cat "$source_file")" "default fallback source"
pass "default replacement mode keeps the legacy commit-list fallback"

(
  cd "$repo"
  HEADING_DATE=2026-07-10 FALLBACK_MODE=preserve GENERATION_SOURCE_FILE="$source_file" \
    bash "$root/gen-changelog.sh" 1.2.0 HEAD > "$output"
)
[ ! -s "$output" ] || fail "preserve fallback emitted content"
assert_equals preserved "$(cat "$source_file")" "preserve source"
pass "preserve fallback is a no-op when no API key is available"

capture="$tmp/request.json"
(
  cd "$repo"
  PATH="$tmp/bin:$PATH" OPENROUTER_API_KEY=test FAKE_CURL_CONTENT=$'- Added a dashboard\n- Fixed startup recovery' \
    CURL_CAPTURE_FILE="$capture" HEADING_DATE=2026-07-10 UPDATE_MODE=highlights \
    FALLBACK_MODE=preserve COMMIT_DETAIL=subjects GENERATION_SOURCE_FILE="$source_file" \
    bash "$root/gen-changelog.sh" 1.2.0 HEAD > "$output"
)
cat > "$tmp/expected" <<'EOF'
## [1.2.0] - 2026-07-10

- Added a dashboard
- Fixed startup recovery
EOF
assert_file_equals "$tmp/expected" "$output" "valid Highlights output"
assert_equals ai "$(cat "$source_file")" "AI source"
user_prompt="$(jq -r '.messages[1].content' "$capture")"
[[ "$user_prompt" == *'fix: second capability'* ]] || fail "subject was omitted from request"
[[ "$user_prompt" != *'SECRET_BODY_SENTINEL'* ]] || fail "commit body leaked in subjects mode"
[[ "$user_prompt" == *'BEGIN UNTRUSTED COMMIT DATA'* ]] || fail "untrusted-data boundary missing"
pass "subjects mode omits commit bodies and marks commit text as untrusted"

(
  cd "$repo"
  PATH="$tmp/bin:$PATH" OPENROUTER_API_KEY=test FAKE_CURL_CONTENT='- Added full commit context' \
    CURL_CAPTURE_FILE="$capture" HEADING_DATE=2026-07-10 GENERATION_SOURCE_FILE="$source_file" \
    bash "$root/gen-changelog.sh" 1.2.0 HEAD > "$output"
)
user_prompt="$(jq -r '.messages[1].content' "$capture")"
[[ "$user_prompt" == *'SECRET_BODY_SENTINEL'* ]] || fail "default full mode omitted commit body"
assert_equals ai "$(cat "$source_file")" "full mode source"
pass "full commit detail remains the default"

(
  cd "$repo"
  PATH="$tmp/bin:$PATH" OPENROUTER_API_KEY=test FAKE_CURL_FAIL=1 \
    UPDATE_MODE=highlights FALLBACK_MODE=preserve GENERATION_SOURCE_FILE="$source_file" \
    bash "$root/gen-changelog.sh" 1.2.0 HEAD > "$output"
)
[ ! -s "$output" ] || fail "network failure emitted content in preserve mode"
assert_equals preserved "$(cat "$source_file")" "network failure source"
pass "OpenRouter failures preserve without emitting fallback content"

(
  cd "$repo"
  PATH="$tmp/bin:$PATH" OPENROUTER_API_KEY=test FAKE_CURL_CONTENT='A paragraph, not a bullet.' \
    UPDATE_MODE=highlights FALLBACK_MODE=preserve GENERATION_SOURCE_FILE="$source_file" \
    bash "$root/gen-changelog.sh" 1.2.0 HEAD > "$output"
)
[ ! -s "$output" ] || fail "invalid AI output was emitted"
assert_equals preserved "$(cat "$source_file")" "invalid output source"
pass "malformed Highlights preserve the changelog"

many_bullets=""
for index in $(seq 1 13); do
  many_bullets+="- Added item $index"$'\n'
done
(
  cd "$repo"
  PATH="$tmp/bin:$PATH" OPENROUTER_API_KEY=test FAKE_CURL_CONTENT="$many_bullets" \
    UPDATE_MODE=highlights FALLBACK_MODE=preserve GENERATION_SOURCE_FILE="$source_file" \
    bash "$root/gen-changelog.sh" 1.2.0 HEAD > "$output"
)
[ ! -s "$output" ] || fail "oversized Highlights output was emitted"
assert_equals preserved "$(cat "$source_file")" "oversized output source"
pass "Highlights are bounded to twelve validated bullets"

(
  cd "$repo"
  UPDATE_MODE=highlights HEADING_DATE=2026-07-10 GENERATION_SOURCE_FILE="$source_file" \
    bash "$root/gen-changelog.sh" 1.2.0 HEAD > "$output"
)
grep -Eq '^- (Added|Changed|Improved|Fixed|Removed) ' "$output" || fail "Highlights fallback has invalid verbs"
[ "$(grep -Ec '^- ' "$output")" -le 12 ] || fail "Highlights fallback is oversized"
assert_equals fallback "$(cat "$source_file")" "Highlights fallback source"
pass "Highlights commit fallback is deterministic and schema-valid"

changelog="$tmp/CHANGELOG.md"
section="$tmp/section.md"
cat > "$changelog" <<'EOF'
# Changelog

Preamble stays exact.

## [1.2.0] - 2026-07-10

### Added

- Existing feature

### Security

- Existing security note

### Known limitations

- Existing limitation

## [1.1.0] - 2026-06-01

- Older release
EOF
cp "$changelog" "$tmp/original-changelog"
cat > "$section" <<'EOF'
## [1.2.0] - 2026-07-10

- Added a dashboard
- Fixed startup recovery
EOF
result_file="$tmp/update-result"
CHANGELOG_FILE="$changelog" UPDATE_MODE=highlights UPDATE_RESULT_FILE="$result_file" \
  bash "$root/update-changelog.sh" 1.2.0 "$section"
cat > "$tmp/expected" <<'EOF'
# Changelog

Preamble stays exact.

## [1.2.0] - 2026-07-10

### Highlights

- Added a dashboard
- Fixed startup recovery

### Added

- Existing feature

### Security

- Existing security note

### Known limitations

- Existing limitation

## [1.1.0] - 2026-06-01

- Older release
EOF
assert_file_equals "$tmp/expected" "$changelog" "Highlights insertion altered canonical sections"
assert_equals updated "$(cat "$result_file")" "insert result"
pass "Highlights insert before canonical sections without rewriting them"

cp "$changelog" "$tmp/once"
CHANGELOG_FILE="$changelog" UPDATE_MODE=highlights UPDATE_RESULT_FILE="$result_file" \
  bash "$root/update-changelog.sh" 1.2.0 "$section"
assert_file_equals "$tmp/once" "$changelog" "Highlights update was not idempotent"
assert_equals unchanged "$(cat "$result_file")" "idempotent result"
pass "Highlights insertion is idempotent"

cat > "$section" <<'EOF'
## [1.2.0] - 2026-07-10

- Improved dashboard navigation
EOF
CHANGELOG_FILE="$changelog" UPDATE_MODE=highlights UPDATE_RESULT_FILE="$result_file" \
  bash "$root/update-changelog.sh" 1.2.0 "$section"
sed '/^### Highlights$/,/^### Added$/{ /^### Added$/!d; }' "$changelog" > "$tmp/without-highlights"
assert_file_equals "$tmp/original-changelog" "$tmp/without-highlights" "non-Highlights bytes changed during replacement"
grep -q '^- Improved dashboard navigation$' "$changelog" || fail "replacement Highlights missing"
pass "Highlights replacement preserves every byte outside its subsection"

cp "$changelog" "$tmp/before-missing"
CHANGELOG_FILE="$changelog" UPDATE_MODE=highlights UPDATE_RESULT_FILE="$result_file" \
  bash "$root/update-changelog.sh" 9.9.9 "$section"
assert_file_equals "$tmp/before-missing" "$changelog" "missing version changed changelog"
assert_equals preserved "$(cat "$result_file")" "missing version result"
pass "missing target versions preserve the changelog"

printf '# Changelog\r\n\r\n## [2.0.0] - 2026-07-10\r\n\r\n### Security\r\n\r\n- Keep me\r\n' > "$changelog"
cat > "$section" <<'EOF'
## [2.0.0] - 2026-07-10

- Added Windows support
EOF
CHANGELOG_FILE="$changelog" UPDATE_MODE=highlights UPDATE_RESULT_FILE="$result_file" \
  bash "$root/update-changelog.sh" 2.0.0 "$section"
perl -e 'local $/; $_=<>; exit(/(?<!\r)\n/ ? 1 : 0)' "$changelog" || fail "CRLF line endings were mixed"
grep -q $'^### Highlights\r$' "$changelog" || fail "CRLF Highlights missing"
pass "Highlights insertion preserves CRLF line endings"

cat > "$changelog" <<'EOF'
# Changelog

## [1.2.0] - 2026-07-10

- Old generated notes

## [1.1.0] - 2026-06-01

- Older release
EOF
cat > "$section" <<'EOF'
## [1.2.0] - 2026-07-11

- New generated notes
EOF
CHANGELOG_FILE="$changelog" UPDATE_MODE=replace-section \
  bash "$root/update-changelog.sh" 1.2.0 "$section"
grep -q '^- New generated notes$' "$changelog" || fail "default updater did not replace section"
if grep -q 'Old generated notes' "$changelog"; then fail "default updater retained old notes"; fi
pass "default whole-section replacement remains intact"

action_tmp="$tmp/action-tmp"
mkdir "$action_tmp"
cat > "$changelog" <<'EOF'
# Changelog

## [1.2.0] - 2026-07-10

### Security

- Existing security note
EOF
github_output="$tmp/github-output"
: > "$github_output"
(
  cd "$repo"
  PATH="$tmp/bin:$PATH" TMPDIR="$action_tmp" VERSION=1.2.0 RANGE=HEAD \
    CHANGELOG_FILE="$changelog" UPDATE_MODE=highlights FALLBACK_MODE=preserve \
    COMMIT_DETAIL=subjects OPENROUTER_API_KEY=test \
    FAKE_CURL_CONTENT='- Added composite output coverage' GITHUB_OUTPUT="$github_output" \
    bash "$root/run-action.sh"
)
assert_equals true "$(output_value changed "$github_output")" "composite changed output"
assert_equals ai "$(output_value generation-source "$github_output")" "composite source output"
persisted_section="$(output_value section-file "$github_output")"
[ -s "$persisted_section" ] || fail "composite section-file did not persist"
grep -q '^## \[1.2.0\]' "$persisted_section" || fail "composite section-file has no candidate heading"
grep -q '^- Added composite output coverage$' "$changelog" || fail "composite Highlights were not applied"
mapfile -t action_temp_files < <(find "$action_tmp" -maxdepth 1 -type f -print)
assert_equals 1 "${#action_temp_files[@]}" "composite auxiliary temporary files"
assert_equals "$persisted_section" "${action_temp_files[0]}" "persisted temporary file"
pass "composite outputs are accurate and only section-file persists"

rm -f "$action_tmp"/*
cat > "$changelog" <<'EOF'
# Changelog

## [1.1.0] - 2026-06-01

- Existing release
EOF
cp "$changelog" "$tmp/composite-before"
: > "$github_output"
capture="$tmp/missing-version-request"
rm -f "$capture"
(
  cd "$repo"
  PATH="$tmp/bin:$PATH" TMPDIR="$action_tmp" VERSION=1.2.0 RANGE=HEAD \
    CHANGELOG_FILE="$changelog" UPDATE_MODE=highlights FALLBACK_MODE=preserve \
    COMMIT_DETAIL=subjects OPENROUTER_API_KEY=test CURL_CAPTURE_FILE="$capture" \
    FAKE_CURL_CONTENT='- Added should not be requested' GITHUB_OUTPUT="$github_output" \
    bash "$root/run-action.sh"
)
assert_file_equals "$tmp/composite-before" "$changelog" "composite missing version changed file"
assert_equals false "$(output_value changed "$github_output")" "missing version changed output"
assert_equals preserved "$(output_value generation-source "$github_output")" "missing version source output"
persisted_section="$(output_value section-file "$github_output")"
[ -f "$persisted_section" ] && [ ! -s "$persisted_section" ] || fail "missing-version section-file is not empty"
[ ! -e "$capture" ] || fail "missing version sent commit data to OpenRouter"
pass "composite missing-version path preserves before generation"

rm -f "$action_tmp"/* "$tmp/missing-changelog"
: > "$github_output"
(
  cd "$repo"
  PATH="$tmp/bin:$PATH" TMPDIR="$action_tmp" VERSION=1.2.0 RANGE=HEAD \
    CHANGELOG_FILE="$tmp/missing-changelog" UPDATE_MODE=highlights FALLBACK_MODE=preserve \
    COMMIT_DETAIL=subjects OPENROUTER_API_KEY=test \
    FAKE_CURL_CONTENT='- Added should not be requested' GITHUB_OUTPUT="$github_output" \
    bash "$root/run-action.sh"
)
[ ! -e "$tmp/missing-changelog" ] || fail "composite created a missing changelog"
assert_equals false "$(output_value changed "$github_output")" "missing file changed output"
assert_equals preserved "$(output_value generation-source "$github_output")" "missing file source output"
persisted_section="$(output_value section-file "$github_output")"
[ -f "$persisted_section" ] && [ ! -s "$persisted_section" ] || fail "missing-file section-file is not empty"
pass "composite missing-file path is a warning-only no-op"

echo "1..$tests"
