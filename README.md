# release-changelog-action

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
  failure, it falls back to a plain commit-subject list.
- Splice is idempotent and format-robust: it replaces an existing
  `## <version>` section (including release-plz/release-please/git-cliff headings
  like `## [0.2.0] - 2026-06-26`) or inserts the new one newest-first.

## Inputs

| input | required | default | description |
|-------|----------|---------|-------------|
| `version` | yes | — | Version being released, e.g. `0.2.0` (no leading `v`). |
| `range` | no | since last tag | git range, e.g. `v0.1.0..HEAD`. |
| `model` | no | `deepseek/deepseek-v4-flash` | OpenRouter model id. |
| `changelog-file` | no | `CHANGELOG.md` | File to update. |
| `openrouter-api-key` | no | — | OpenRouter key. Empty → fallback list. |
| `project-name` | no | repo name | Project name for prompt context. |
| `project-description` | no | — | One-line project description for context. |

## Outputs

| output | description |
|--------|-------------|
| `section-file` | Path to a file holding just the generated `## <version>` section. |
| `changed` | `'true'` if the changelog file content changed. |

## Usage — Rust (release-plz)

In the `release-pr` job, after the `release-plz/action` step (which has `id: release-plz`):

```yaml
- name: Check out the Release PR
  if: ${{ steps.release-plz.outputs.pr != '' }}
  env:
    GH_TOKEN: ${{ secrets.RELEASE_PLZ_TOKEN }}
  run: |
    pr="$(jq -r '.number // empty' <<<'${{ steps.release-plz.outputs.pr }}')"
    ver="$(jq -r '.releases[0].version // empty' <<<'${{ steps.release-plz.outputs.pr }}')"
    [ -n "$pr" ] && [ -n "$ver" ] || exit 0
    gh pr checkout "$pr"
    { echo "RP_PR=$pr"; echo "RP_VER=$ver"; } >> "$GITHUB_ENV"

- name: AI changelog
  if: ${{ env.RP_PR != '' }}
  uses: grok-insider/release-changelog-action@v1
  with:
    version: ${{ env.RP_VER }}
    openrouter-api-key: ${{ secrets.OPENROUTER_API_KEY }}

- name: Commit changelog to the Release PR
  if: ${{ env.RP_PR != '' }}
  run: |
    git config user.name "github-actions[bot]"
    git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
    if ! git diff --quiet -- CHANGELOG.md; then
      git add CHANGELOG.md
      git commit -m "docs(changelog): generate release notes for v${RP_VER}"
      git push
    fi
```

The checkout step needs `persist-credentials: true` + `token: ${{ secrets.RELEASE_PLZ_TOKEN }}` so the push lands on the PR branch and triggers CI.

## Usage — Python (release-please)

After the `googleapis/release-please-action` step (with `id: rp`), when it opened
a PR (`steps.rp.outputs.prs_created == 'true'` / `pr` output), check out that PR,
run this action with the version release-please computed, commit, and push.

## License

MIT © Grok Insider
