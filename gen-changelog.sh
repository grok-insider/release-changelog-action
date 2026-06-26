#!/usr/bin/env bash
#
# gen-changelog.sh — generate a single CHANGELOG section for one release, written
# in the user-facing "claude-code" style by an LLM via OpenRouter.
#
# Usage:
#   gen-changelog.sh <version> [<git-range>]
#
# Output (stdout): a markdown section beginning with `## <version>`, e.g.
#   ## 0.2.0
#
#   - Added ...
#   - Fixed ...
#
# Environment:
#   OPENROUTER_API_KEY    OpenRouter key. If unset/empty, falls back to a plain
#                         commit-subject list (no network call).
#   CHANGELOG_MODEL       Model id (default: deepseek/deepseek-v4-flash).
#   OPENROUTER_BASE_URL   API base (default: https://openrouter.ai/api/v1).
#   PROJECT_NAME          Optional project name, for prompt context.
#   PROJECT_DESCRIPTION   Optional one-line project description, for prompt context.
#
# This script never fails the caller: on any error (missing key, network/API
# failure, empty model output) it prints a deterministic fallback section so a
# release is never blocked by changelog generation.

set -uo pipefail

version="${1:?usage: gen-changelog.sh <version> [<git-range>]}"
range="${2:-HEAD}"
model="${CHANGELOG_MODEL:-deepseek/deepseek-v4-flash}"
base_url="${OPENROUTER_BASE_URL:-https://openrouter.ai/api/v1}"
project_name="${PROJECT_NAME:-this project}"
project_description="${PROJECT_DESCRIPTION:-}"

# Plain, dependency-free fallback: bullet list of commit subjects.
emit_fallback() {
  printf '## %s\n\n' "$version"
  local subjects
  subjects="$(git log --no-merges --pretty=format:'- %s' "$range" 2>/dev/null)"
  if [ -n "$subjects" ]; then
    printf '%s\n' "$subjects"
  else
    printf -- '- Internal improvements and maintenance\n'
  fi
}

# Collect the commit messages (subject + body) for the range, capped so a huge
# range can't blow past sane request sizes.
commits="$(git log --no-merges --pretty=format:'- %s%n%b' "$range" 2>/dev/null | sed '/^[[:space:]]*$/d')"
commits="$(printf '%s' "$commits" | head -c 60000)"

if [ -z "${OPENROUTER_API_KEY:-}" ] || [ -z "$commits" ]; then
  emit_fallback
  exit 0
fi

ctx="$project_name"
if [ -n "$project_description" ]; then
  ctx="$project_name ($project_description)"
fi

read -r -d '' system_prompt <<EOF || true
You write release notes for the open-source project "${ctx}", in the exact style
of the Anthropic "claude-code" CHANGELOG.

Rules:
- Output ONLY a flat markdown bullet list. No headings, no version number, no
  preamble, no trailing remarks, no code fences.
- One bullet per user-facing change. Begin each bullet with a verb: "Added",
  "Changed", "Improved", "Fixed", or "Removed".
- Order the bullets: Added first, then Changed, Improved, Fixed, Removed.
- Write for end users, not contributors. Describe the observable effect, not the
  implementation or the raw commit message. Keep each bullet to one line.
- Do NOT include commit hashes, PR numbers, author names, or branch names.
- Omit purely internal changes with no user-visible effect (CI, refactors,
  formatting, test-only, dependency bumps) unless they change behavior.
- Never invent changes; summarize only what the commits indicate. If there is
  nothing user-facing, output exactly: - Internal improvements and maintenance
EOF

user_prompt="Project version being released: ${version}

Commits since the last release:
${commits}"

payload="$(jq -n \
  --arg model "$model" \
  --arg sys "$system_prompt" \
  --arg usr "$user_prompt" \
  '{model: $model, temperature: 0.2, messages: [
     {role: "system", content: $sys},
     {role: "user", content: $usr}
   ]}')"

response="$(curl -sS --max-time 120 \
  -H "Authorization: Bearer ${OPENROUTER_API_KEY}" \
  -H "Content-Type: application/json" \
  -H "HTTP-Referer: https://github.com/grok-insider/release-changelog-action" \
  -H "X-Title: release-changelog-action" \
  -d "$payload" \
  "${base_url}/chat/completions" 2>/dev/null)" || { emit_fallback; exit 0; }

content="$(printf '%s' "$response" | jq -r '.choices[0].message.content // empty' 2>/dev/null)"
if [ -z "$content" ]; then
  emit_fallback
  exit 0
fi

# Sanitize: drop code fences and any stray markdown headings the model may have
# added, then trim leading/trailing blank lines.
content="$(printf '%s\n' "$content" \
  | sed -e '/^[[:space:]]*```/d' -e '/^[[:space:]]*#\{1,6\}[[:space:]]/d' \
  | sed -e ':a' -e '/^[[:space:]]*$/{$d;N;ba}' \
  | awk 'NF{found=1} found{print}')"

if [ -z "$content" ]; then
  emit_fallback
  exit 0
fi

printf '## %s\n\n%s\n' "$version" "$content"
