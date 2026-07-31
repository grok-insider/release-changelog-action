# release-changelog-action

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Uses](https://img.shields.io/badge/uses-grok--insider%2Frelease--changelog--action%40v1-purple)](https://github.com/grok-insider/release-changelog-action)

A small composite GitHub Action that generates **user-facing, "claude-code"-style
release notes** from your git history using an LLM via
[OpenRouter](https://openrouter.ai). It can replace a complete `CHANGELOG.md`
version section or manage only a bounded `### Highlights` subsection.

It is the shared, single-source changelog brain behind the grok-insider release
pipelines. The release tool (release-plz for Rust, release-please for npm/Python)
opens the standing **Release PR**; this action rewrites that PR's changelog
section with readable prose; merging the PR cuts the tag + GitHub Release +
artifacts. The action only **generates + splices** — the caller checks out the
Release PR, commits, and pushes (it owns the PR context and token).

## Behaviour

- Summarizes `git log` for the release range into grouped bullets
  (Added / Changed / Improved / Fixed / Removed), one line each, no commit
  hashes or PR numbers.
- **Never blocks a release:** with no `openrouter-api-key`, or on any API/network
  failure, the default mode falls back to a plain commit-subject list. Set
  `fallback-mode: preserve` to leave the changelog untouched instead.
- Splice is idempotent and format-robust: it replaces an existing
  `## <version>` section (including release-plz/release-please/git-cliff headings
  like `## [0.2.0] - 2026-06-26`) or inserts the new one newest-first.
- `update-mode: highlights` requires an existing target version section and only
  inserts or replaces `### Highlights`. All other content, including Security
  and Known limitations, is preserved byte-for-byte. Missing target sections are
  warning-only no-ops; malformed AI output and unavailable generation are also
  no-ops when `fallback-mode: preserve` is selected.
- Highlights accept 1–12 one-line bullets beginning with Added, Changed,
  Improved, Fixed, or Removed. Commit messages are treated as untrusted prompt
  data rather than model instructions.


## Publish GitHub Release notes (optional)

After a tag exists, product workflows can call the same action to set the Release
body from the CHANGELOG section (and an optional footer), without calling OpenRouter:

```yaml
- uses: actions/checkout@v4
  with:
    ref: ${{ needs.resolve.outputs.tag }}
- uses: grok-insider/release-changelog-action@v1
  with:
    version: ${{ needs.resolve.outputs.version }}
    skip-generate: true
    publish-github-release: true
    github-token: ${{ secrets.GITHUB_TOKEN }}
    tag: ${{ needs.resolve.outputs.tag }}
    notes-footer-file: site/release-footer.md
```

`extract-section.sh` powers the body extract (Keep a Changelog / plain headings).
`publish-github-release.sh` runs `gh release edit` or `create`.

## Requirements

- Runs on a runner with `bash`, `jq`, `curl`, `git`, `awk`, `sed`, `perl` (all
  present on GitHub-hosted Ubuntu runners).
- **Check out full history + tags** (`fetch-depth: 0`). The action runs
  `git describe --tags` / `git log <range>`; a shallow clone breaks range
  detection.

## Setup (secrets)

- **`OPENROUTER_API_KEY`** — create a key at
  [openrouter.ai/keys](https://openrouter.ai/keys) and add it as a repo secret.
  Pass it via `openrouter-api-key`. Without it the action applies the selected
  fallback behavior.
- **Release automation token** (a fine-grained PAT, with a caller-defined secret
  name such as `RELEASE_AUTOMATION_TOKEN`) — used by the *caller* to create and
  update the Release PR. Grant only the repository permissions the release tool
  needs. Use it when those bot changes must start required CI normally rather
  than relying on the default `GITHUB_TOKEN` recursion protections or
  approval-required pull-request runs.

## Inputs

| input | required | default | description |
|-------|----------|---------|-------------|
| `version` | yes | — | Version being released, e.g. `0.2.0` (no leading `v`). |
| `range` | no | since last tag | git range, e.g. `v0.1.0..HEAD`. Empty → latest `v*` tag..HEAD (or whole history). Prefer an explicit range on hand-rolled release PRs. |
| `model` | no | `deepseek/deepseek-v4-flash-0731` | OpenRouter model id. |
| `changelog-file` | no | `CHANGELOG.md` | File to update. |
| `openrouter-api-key` | no | — | OpenRouter key. Empty → selected fallback behavior. |
| `openrouter-base-url` | no | `https://openrouter.ai/api/v1` | OpenRouter-compatible API base (proxy/mirror). |
| `project-name` | no | repo name | Project name for prompt context. |
| `project-description` | no | — | One-line project description for context. |
| `heading-style` | no | `keepachangelog` | `keepachangelog` → `## [X.Y.Z] - YYYY-MM-DD`; `plain` → bare `## X.Y.Z`. |
| `update-mode` | no | `replace-section` | `replace-section` manages the complete version section; `highlights` manages only `### Highlights` inside an existing section. |
| `fallback-mode` | no | `commit-list` | `commit-list` emits deterministic commit bullets; `preserve` leaves the changelog unchanged when generation fails. |
| `commit-detail` | no | `full` | `full` sends commit subjects and bodies to OpenRouter; `subjects` sends subjects only. |
| `skip-generate` | no | `false` | Skip AI/CHANGELOG rewrite; only extract + publish. Requires `publish-github-release`. |
| `publish-github-release` | no | `false` | Set GitHub Release body from CHANGELOG section (+ footer). |
| `github-token` | if publishing | — | Token for `gh release edit/create`. |
| `tag` | if publishing | `v${version}` | Release tag. |
| `notes-footer` / `notes-footer-file` | no | — | Optional markdown appended after the section. |

The **minimal** call passes only `version` + `openrouter-api-key` (the real
consumers also pass `project-description` and usually `range`); everything else
has a sane default. Headings default to Keep a Changelog form so callers do not
need a post-sed normalize step.

## Outputs

| output | description |
|--------|-------------|
| `section-file` | Path to the generated candidate version section (heading + bullets). In Highlights mode the action extracts those bullets into `### Highlights`; preserved runs leave this file empty. The file remains available to later steps in the same job. |
| `changed` | `'true'` if the changelog file content changed, else `'false'`. |
| `generation-source` | `ai`, `fallback`, or `preserved`. |
| `notes-file` | Assembled GitHub Release notes path (when built). |
| `published` | `true` if a Release was created/edited. |

## Usage — preserve canonical changelog sections

Use Highlights mode when the release tool owns deterministic Added, Changed,
Security, or Known limitations sections. This is the recommended configuration
for safety-sensitive projects:

```yaml
- name: Generate release highlights
  id: changelog
  uses: grok-insider/release-changelog-action@<full-commit-sha>
  with:
    version: ${{ env.RP_VER }}
    openrouter-api-key: ${{ secrets.OPENROUTER_API_KEY }}
    update-mode: highlights
    fallback-mode: preserve
    commit-detail: subjects
    project-description: "Safety-first desktop automation and app QA."
```

The release tool must create the version section before this step. If it has
not, `generation-source` is `preserved`, `changed` is `false`, and the existing
file is left untouched. Subjects mode also limits the repository data sent to
OpenRouter; full mode includes commit bodies for richer summaries.

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

## Usage — hand-rolled patch-line release PR (open-recorder style)

When the automatic stream only bumps **patch** (`x.y.z → x.y.z+1`) and major/minor
go through a separate admin workflow:

```yaml
- name: Generate the AI changelog section
  uses: grok-insider/release-changelog-action@v1
  with:
    version: ${{ steps.decide.outputs.next }}       # e.g. 0.2.1
    range: v${{ steps.decide.outputs.current }}..HEAD
    openrouter-api-key: ${{ secrets.OPENROUTER_API_KEY }}
    project-description: "One-line description of your project."
# Heading is already `## [0.2.1] - YYYY-MM-DD` — no sed normalize needed.
```

Always pass an explicit `range` so the notes cover the same commits as the version
decision (`vCURRENT..HEAD` on master), not whatever is on a force-pushed PR branch.

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

## Contributing

The action is plain bash — no build step. Before opening a PR against
`master`, run what CI runs:

```sh
bash tests/test.sh          # deterministic tests (fake curl, no network)
shellcheck gen-changelog.sh run-action.sh update-changelog.sh update-highlights.sh tests/*.sh
actionlint                  # validates .github/workflows
```

New inputs must be documented in both `action.yml` and this README, wired
through `run-action.sh` as environment variables, and covered by a test in
`tests/test.sh`.

## License

MIT © Grok Insider
