# Maintainer cheatsheet — ddev-claude

Quick reference for me. Full rationale: [`MAINTAINING.md`](./MAINTAINING.md).

## Daily / weekly
- **Triage new issues:** label (`bug`/`enhancement`/`question`/`docs`/`security`, `area/*`), ask for repro → `needs-repro`, close dupes with a link.
- **PR queue:** acknowledge within a few days even if just "queued." Squash-merge with a clean Conventional-Commit title.
- Stale bot handles idle `needs-repro` issues automatically (`.github/workflows/stale.yml`).
- Dependabot PRs land Mondays — review `area/ci` + `area/image`, merge if CI green.

## Cut a release
```bash
# 1. main is green, all PRs merged
# 2. finalize CHANGELOG: move [Unreleased] -> [vX.Y.Z] — YYYY-MM-DD, leave empty [Unreleased]
git tag -a v0.3.0 -m "v0.3.0"
git push origin v0.3.0            # triggers publish-image.yml -> GHCR

# 3. verify image (both arches)
docker buildx imagetools inspect ghcr.io/makraz/ddev-claude-base:v0.3.0

# 4. GitHub Release from tag, changelog as body (mark pre-release for -beta.N)
# 5. smoke test
ddev add-on get makraz/ddev-claude@v0.3.0 && ddev restart && ddev claude help
```
Open a **Release checklist** issue (template) to track each one.

## SemVer for an add-on
- **MAJOR** — breaks `.ddev/claude.yaml` schema / removes commands / forces edits to committed `.ddev/` files.
- **MINOR** — new extras, commands, opt-in behavior. Backward compatible.
- **PATCH** — firewall/Dockerfile/doc-only fixes & image rebuilds.
- Pre-1.0: may fold breaks into MINOR, but shout about them in the changelog.
- Image tag is pinned **1:1** to the add-on version — no floating `:latest`.

## Red-flag PRs (extra scrutiny)
Anything touching `image/`, firewall scripts, `extra-domains.list`, allowed-domains, or `--dangerously-skip-permissions`. The sandbox **is** the product — review against `SECURITY.md` threat model.

## Feature planning
- Small (extras/commands/docs): issue → discuss → build.
- Touches the security boundary or schema: write a design doc in `docs/superpowers/specs/`, open it as a PR, **merge the design before coding**. Track `proposed → accepted → implemented → released`.

## Files that drive process
| File | Purpose |
| --- | --- |
| `.github/labels.sh` | Idempotent label sync (`./.github/labels.sh`) |
| `.github/dependabot.yml` | Weekly Actions + Docker base-image bumps |
| `.github/workflows/stale.yml` | Auto-chase `needs-repro` issues |
| `.github/workflows/tests.yml` | CI gate (bats unit + integration) |
| `.github/workflows/publish-image.yml` | Builds/publishes GHCR image on tag push |
| `.github/ISSUE_TEMPLATE/release_checklist.yml` | Per-release tracking issue |
| `CHANGELOG.md` | Keep a Changelog — the doc users judge us by |
| `SECURITY.md` | Threat model + private reporting path |
