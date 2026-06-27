# release-changelog-action

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Uses](https://img.shields.io/badge/uses-grok--insider%2Frelease--changelog--action%40v1-purple)](https://github.com/grok-insider/release-changelog-action)

A small composite GitHub Action that generates a **user-facing, "claude-code"-style
`CHANGELOG.md` section** from your git history using an LLM via
[OpenRouter](https://openrouter.ai), and splices it into your changelog file.

It is the shared, single-source changelog brain behind the grok-insider release
pipelines. The release tool (release-plz for Rust, release-please for Python)
opens the standing **Release PR**; this action rewrites that PR's changelog
section with readable prose; merging the PR cuts the tag + GitHub Release +
artifacts. The action only **generates + splices** — the caller checks out the
Release PR, commits, and pushes (it owns the PR context and token).

## Behaviour

- Summarizes `git log` for the release range into grouped bullets
  (Added / Changed / Improved / Fixed / Removed), one line each, no commit
  hashes or PR numbers.
- **Never blocks a release:** with no `openrouter-api-key`, or on any API/network
  failure, it falls back to a plain commit-subject list (or, when there's nothing
  user-facing, the single line `- Internal improvements and maintenance`).
- Splice is idempotent and format-robust: it replaces an existing
  `## <version>` section (including release-plz/release-please/git-cliff headings
  like `## [0.2.0] - 2026-06-26`) or inserts the new one newest-first.

## Requirements

- Runs on a runner with `bash`, `jq`, `curl`, `git`, `awk`, `sed` (all present on
  `ubuntu-latest`).
- **Check out full history + tags** (`fetch-depth: 0`). The action runs
  `git describe --tags` / `git log <range>`; a shallow clone breaks range
  detection.

## Setup (secrets)

- **`OPENROUTER_API_KEY`** — create a key at
  [openrouter.ai/keys](https://openrouter.ai/keys) and add it as a repo secret.
  Pass it via `openrouter-api-key`. Without it the action still runs and falls
  back to a commit-subject list.
- **`RELEASE_PLZ_TOKEN`** (a PAT) — used by the *caller* to push the changelog
  commit back to the Release PR branch. This is required because a commit pushed
  with the default `GITHUB_TOKEN` does **not** re-trigger required status checks,
  so the Release PR would never go green.

## Inputs

| input | required | default | description |
|-------|----------|---------|-------------|
| `version` | yes | — | Version being released, e.g. `0.2.0` (no leading `v`). |
| `range` | no | since last tag | git range, e.g. `v0.1.0..HEAD`. Empty → `git describe`-derived `prev..HEAD` (or whole history). |
| `model` | no | `deepseek/deepseek-v4-flash` | OpenRouter model id. |
| `changelog-file` | no | `CHANGELOG.md` | File to update. |
| `openrouter-api-key` | no | — | OpenRouter key. Empty → fallback list. |
| `openrouter-base-url` | no | `https://openrouter.ai/api/v1` | OpenRouter-compatible API base (proxy/mirror). |
| `project-name` | no | repo name | Project name for prompt context. |
| `project-description` | no | — | One-line project description for context. |

The **minimal** call passes only `version` + `openrouter-api-key` (the six real
consumers also pass `project-description`); everything else has a sane default.

## Outputs

| output | description |
|--------|-------------|
| `section-file` | Path to a file holding just the generated `## <version>` section. |
| `changed` | `'true'` if the changelog file content changed, else `'false'`. |

## Usage — Rust (release-plz)

```yaml
jobs:
  release-pr:
    runs-on: ubuntu-latest
    permissions:
      contents: write
      pull-requests: write
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0            # full history + tags (required)
          persist-credentials: true
          token: ${{ secrets.RELEASE_PLZ_TOKEN }}

      - uses: release-plz/action@v0.5
        id: release-plz
        with:
          command: release-pr
        env:
          GITHUB_TOKEN: ${{ secrets.RELEASE_PLZ_TOKEN }}

      - name: Check out the Release PR
        if: ${{ steps.release-plz.outputs.pr != '' }}
        env:
          GH_TOKEN: ${{ secrets.RELEASE_PLZ_TOKEN }}
          PR_JSON: ${{ steps.release-plz.outputs.pr }}   # via env, not inline ${{ }}
        run: |
          set -euo pipefail
          pr="$(jq -r '.number // empty' <<<"$PR_JSON")"
          ver="$(jq -r '.releases[0].version // empty' <<<"$PR_JSON")"
          [ -n "$pr" ] && [ -n "$ver" ] || exit 0
          gh pr checkout "$pr"
          { echo "RP_PR=$pr"; echo "RP_VER=$ver"; } >> "$GITHUB_ENV"

      - name: AI changelog
        if: ${{ env.RP_PR != '' }}
        uses: grok-insider/release-changelog-action@v1
        with:
          version: ${{ env.RP_VER }}
          openrouter-api-key: ${{ secrets.OPENROUTER_API_KEY }}
          project-description: "One-line description of your project."

      - name: Commit changelog to the Release PR
        if: ${{ env.RP_PR != '' }}
        run: |
          set -euo pipefail
          git config user.name "github-actions[bot]"
          git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
          if ! git diff --quiet -- CHANGELOG.md; then
            git add CHANGELOG.md
            git commit -m "docs(changelog): generate release notes for v${RP_VER}"
            git push
          fi
```

> Pass the PR JSON through `env:` (`PR_JSON`) and read it with `<<<"$PR_JSON"` —
> never interpolate `${{ steps… }}` directly inside the `run:` script (that breaks
> on quotes and is script-injection-prone).

## Usage — Python (release-please)

```yaml
jobs:
  release-please:
    runs-on: ubuntu-latest
    permissions:
      contents: write
      pull-requests: write
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
          persist-credentials: true
          token: ${{ secrets.RELEASE_PLZ_TOKEN }}

      - uses: googleapis/release-please-action@v4
        id: rp
        with:
          token: ${{ secrets.RELEASE_PLZ_TOKEN }}

      - name: Check out the Release PR
        if: ${{ steps.rp.outputs.prs_created == 'true' }}
        env:
          GH_TOKEN: ${{ secrets.RELEASE_PLZ_TOKEN }}
          PR_JSON: ${{ steps.rp.outputs.pr }}
        run: |
          set -euo pipefail
          pr="$(jq -r '.number // empty' <<<"$PR_JSON")"
          [ -n "$pr" ] || exit 0
          gh pr checkout "$pr"
          ver="$(grep -m1 -E '^version *= *"' pyproject.toml | sed -E 's/.*"([^"]+)".*/\1/')"
          { echo "RP_PR=$pr"; echo "RP_VER=$ver"; } >> "$GITHUB_ENV"

      - name: AI changelog
        if: ${{ env.RP_PR != '' }}
        uses: grok-insider/release-changelog-action@v1
        with:
          version: ${{ env.RP_VER }}
          openrouter-api-key: ${{ secrets.OPENROUTER_API_KEY }}
          project-description: "One-line description of your project."

      - name: Commit changelog to the Release PR
        if: ${{ env.RP_PR != '' }}
        run: |
          set -euo pipefail
          git config user.name "github-actions[bot]"
          git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
          if ! git diff --quiet -- CHANGELOG.md; then
            git add CHANGELOG.md
            git commit -m "docs(changelog): generate release notes for v${RP_VER}"
            git push
          fi
```

## Using the outputs

The caller usually just re-checks `git diff`, but you can branch on the outputs
instead:

```yaml
      - name: AI changelog
        id: changelog
        uses: grok-insider/release-changelog-action@v1
        with:
          version: ${{ env.RP_VER }}
          openrouter-api-key: ${{ secrets.OPENROUTER_API_KEY }}

      - name: Use the result
        if: ${{ steps.changelog.outputs.changed == 'true' }}
        run: cat "${{ steps.changelog.outputs.section-file }}"
```

## Versioning

`@v1` is a **moving major tag** — it tracks the latest backward-compatible
release, so you get fixes automatically. For fully reproducible builds, pin to a
commit SHA instead:

```yaml
uses: grok-insider/release-changelog-action@<full-commit-sha>  # immutable
```

## License

MIT © Grok Insider
