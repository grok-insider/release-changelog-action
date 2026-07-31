# AGENTS.md — release-changelog-action

Shared **composite GitHub Action** (pure bash, no build step): git history →
Keep-a-Changelog release notes via OpenRouter. Product shippers pin
**`grok-insider/release-changelog-action@v1`**.

## Commands

```sh
bash tests/test.sh          # full deterministic test suite (no network; uses tests/fake-curl.sh)
shellcheck gen-changelog.sh run-action.sh update-changelog.sh update-highlights.sh extract-section.sh publish-github-release.sh tests/*.sh
actionlint                  # validates .github/workflows/ci.yml
```

CI (`.github/workflows/ci.yml`) runs exactly these three on push to `master`
and on PRs. Keep ShellCheck 0.11 clean.

## Architecture

- `action.yml` — composite action; maps every input to an env var
  (`VERSION`, `RANGE`, `UPDATE_MODE`, `FALLBACK_MODE`, `COMMIT_DETAIL`,
  `CHANGELOG_FILE`, `OPENROUTER_*`, `CHANGELOG_MODEL`, `PROJECT_*`,
  `HEADING_STYLE`) and runs `run-action.sh`.
- `run-action.sh` — orchestrator. Validates enum inputs, resolves the default
  range (latest `v*` tag..HEAD, else whole history), calls `gen-changelog.sh`
  into a temp section file, then `update-changelog.sh`; writes the three
  outputs (`section-file`, `changed`, `generation-source`) to `GITHUB_OUTPUT`.
  The section file is deliberately NOT cleaned up by the exit trap so later
  workflow steps can read it.
- `gen-changelog.sh` — produces one version section on stdout
  (`## [X.Y.Z] - date` heading + bullets). Calls OpenRouter via `curl`+`jq`;
  on any failure (no key, network error, empty/invalid content) applies
  `FALLBACK_MODE`: `commit-list` (deterministic commit-subject bullets) or
  `preserve` (empty output). Reports `ai`/`fallback`/`preserved` through
  `GENERATION_SOURCE_FILE`. Commit text is wrapped as untrusted data in the
  prompt; highlights bullets are strictly validated (1–12 lines, verb-prefixed,
  <=500 chars, no control chars). Never fails the caller for generation errors.
- `update-changelog.sh` — awk splice of the section into `CHANGELOG_FILE`:
  replaces an existing section for the version (any heading format — plain,
  `[x.y.z] - date`, or linked) or inserts newest-first; preserves the
  preamble. Delegates `UPDATE_MODE=highlights` to `update-highlights.sh`.
- `update-highlights.sh` — perl; inserts/replaces only `### Highlights` inside
  an existing version section, byte-preserving everything else (incl. CRLF).
  Missing section or empty input is a warning-only no-op (`preserved` via
  `UPDATE_RESULT_FILE`).
- `extract-section.sh` / `publish-github-release.sh` — optional GitHub Release body from a CHANGELOG section + footer (`skip-generate` + `publish-github-release`).
- `tests/test.sh` — 40+ assertions against a scratch git repo;
  `tests/fake-curl.sh` shadows `curl` on PATH (`FAKE_CURL_CONTENT`,
  `FAKE_CURL_FAIL`, `CURL_CAPTURE_FILE`).

## Conventions

- Default branch: **`master`**; simple PR-to-master workflow. This repo has no
  release-plz/please pipeline of its own.
- Breaking changes to inputs/outputs affect **every** consumer — `@v1` is a
  moving major tag; bump it only with intent.
- New inputs: document in `action.yml` and `README.md`, wire through
  `run-action.sh` env, add a test in `tests/test.sh`.
- Stay dependency-light: bash, git, jq, curl, awk, sed, perl (all present on
  GitHub-hosted Ubuntu runners).
- Keep the `commit-list` fallback reliable — the action must never block a
  release. Never commit API keys.

## Org QC

Scoreboard: `~/dev/opensource/docs/comparison.md` (shared infra row).
Releases architecture: `~/dev/opensource/docs/releases.md`.
