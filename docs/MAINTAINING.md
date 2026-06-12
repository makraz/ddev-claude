# Maintaining ddev-claude

A practical maintainer playbook for this add-on, modeled on the conventions of
well-run public repositories. Each section names the repos worth imitating and
why.

> **Reference repos to study**
> - [ddev/ddev](https://github.com/ddev/ddev) and [ddev/ddev-addon-template](https://github.com/ddev/ddev-addon-template) — your ecosystem's house style; match it.
> - [cli/cli](https://github.com/cli/cli) (GitHub CLI) — issue triage labels, release notes, RFC-style proposals.
> - [vercel/next.js](https://github.com/vercel/next.js) — issue templates that demand reproductions, stale-bot policy.
> - [sveltejs/svelte](https://github.com/sveltejs/svelte) and [yarnpkg/berry](https://github.com/yarnpkg/berry) — Changesets-driven releases.
> - [rust-lang/rust](https://github.com/rust-lang/rust) RFC process, [tc39/proposals](https://github.com/tc39/proposals) staging — for heavyweight feature planning.
> - [semantic-release/semantic-release](https://github.com/semantic-release/semantic-release) — Conventional Commits → automated releases.

---

## 1. Releases

This project already declares its contract: **[SemVer](https://semver.org)** +
**[Keep a Changelog](https://keepachangelog.com)**, with the image tag pinned 1:1
to the add-on version. Protect that contract.

### Versioning rules (SemVer, applied to an add-on)
- **MAJOR** — breaking changes to `.ddev/claude.yaml` schema, removed commands, or anything forcing users to edit committed `.ddev/` files. Pre-1.0 you *may* bump minor instead, but document the break loudly.
- **MINOR** — new extras, new commands, new opt-in behavior. Backward compatible.
- **PATCH** — firewall fixes, Dockerfile fixes, doc-only image rebuilds.
- **Pre-release** — keep using `vX.Y.Z-beta.N` (you already do for `v0.3.0-beta.1`). Mark them as "pre-release" on GitHub so `ddev add-on get` resolves stable by default.

### Release checklist
1. **Land all PRs** targeting the release; ensure `tests.yml` is green on `main`.
2. **Finalize the changelog.** Move everything under `## [Unreleased]` into a new `## [vX.Y.Z] — YYYY-MM-DD` section. Keep the `Unreleased` heading empty for next time. (Keep a Changelog convention.)
3. **Tag, don't hand-build.** Push an annotated tag — `publish-image.yml` builds and publishes `ghcr.io/makraz/ddev-claude-base:<version>` on tag push:
   ```bash
   git tag -a v0.3.0 -m "v0.3.0"
   git push origin v0.3.0
   ```
4. **Verify the image published** (both arches) before announcing: `docker buildx imagetools inspect ghcr.io/makraz/ddev-claude-base:v0.3.0`.
5. **Create the GitHub Release** from the tag. Paste the changelog section as the release body. Link it from the README badge (already wired).
6. **Smoke test the published artifact** exactly as a user would: `ddev add-on get makraz/ddev-claude@v0.3.0 && ddev restart && ddev claude help`.

> **Adopt the Keep-a-Changelog discipline religiously.** The single best signal of a
> trustworthy package is that its changelog tells users what *they* need to do, not
> what the commit log says. Write entries for humans: "Set `EXTRA_ALLOWED_DOMAINS`
> before `ddev restart` — it's now applied at container start" not "refactor fw.sh".

### Optional automation (when manual release becomes a chore)
- **[Changesets](https://github.com/changesets/changesets)** (svelte, yarn) — contributors add a `.changeset/*.md` per PR describing the bump; a bot opens a "Version Packages" PR. Great fit because it keeps the changelog human-authored.
- **[release-please](https://github.com/googleapis/release-please)** or **semantic-release** — fully automated from Conventional Commits. More magic, less prose control. Adopt only once commit hygiene is enforced.

---

## 2. Pull Requests

Model: **GitHub CLI (`cli/cli`)** — small, well-labeled, every PR maps to an issue.

### The flow
1. **Issue first, PR second.** Non-trivial PRs should reference an accepted issue. This avoids "great patch, wrong direction" rejections. (`cli/cli`, `next.js` both enforce this socially.)
2. **Branch naming** — keep the `type/slug` convention already in your history (`feat/prebuilt-image`, `chore/bump-actions-node24`, `fix/...`, `docs/...`).
3. **PR template** (you have `.github/PULL_REQUEST_TEMPLATE.md`) should force: *what & why*, linked issue (`Closes #N`), test evidence, changelog entry added under `Unreleased`.
4. **CI is the gatekeeper.** `tests.yml` (bats unit + integration; PRs build the base image locally) must pass. Branch-protect `main`: require the check + 1 review, no direct pushes.
5. **Review for the threat model, not just correctness.** This package's whole value proposition is the firewall sandbox. Any PR touching `image/`, firewall scripts, allowed-domains, or `--dangerously-skip-permissions` paths gets extra scrutiny — see `SECURITY.md`.
6. **Squash-merge** with a clean Conventional-Commit-style title. Keeps `main` history linear and changelog-friendly.

### Maintainer etiquette (borrow from large OSS)
- Respond within a few days even if just "thanks, queued for review."
- Push fixups to a contributor's branch only with permission; otherwise request changes.
- Be explicit when declining: explain the *why* and link the threat model / scope doc. A clear "no" beats a stale PR.

---

## 3. Issues

Model: **`next.js` / `cli/cli`** — templates that demand reproductions, ruthless labeling, honest stale policy.

### Templates
You already have `bug_report.yml`, `feature_request.yml`, and `config.yml`. Keep bug reports **requiring**: DDEV version, OS/arch, add-on version, exact `ddev claude ...` command, and what the firewall/logs showed. "No reproduction" is the #1 reason issues rot.

### Triage labels (a minimal, proven set)
- **Type:** `bug`, `enhancement`, `question`, `docs`, `security`
- **Status:** `needs-repro`, `needs-triage`, `confirmed`, `blocked`, `wontfix`
- **Effort/impact:** `good first issue`, `help wanted` (drives contribution — see `cli/cli`)
- **Area:** `area/firewall`, `area/image`, `area/extras`, `area/ci`

### Triage cadence
- **Weekly triage pass:** label new issues, close duplicates with a link, ask for repro on anything vague.
- **Stale policy:** consider [`actions/stale`](https://github.com/actions/stale) — mark `needs-repro` issues stale after ~30 days idle, close after ~14 more. Always allow reopen. (next.js, kubernetes use this.)
- **Convert questions to Discussions** if you enable GitHub Discussions; keep Issues for actionable work.

---

## 4. Planning new features

You already have a strong, lightweight habit: **spec + plan docs in `docs/superpowers/`**
(`*-design.md` specs, `*.md` plans). Formalize it by scaling process to risk.

### Lightweight (default) — for extras, commands, doc work
1. Open an `enhancement` issue describing the problem and proposed shape.
2. Discuss in-thread; reach rough consensus.
3. Implement behind the existing config surface (`.ddev/claude.yaml`, extras catalog).

### Heavyweight (RFC) — for anything touching the security boundary or schema
Adopt a tiny **RFC process** (model: [rust-lang/rfcs](https://github.com/rust-lang/rfcs), [reactjs/rfcs](https://github.com/reactjs/rfcs), [tc39 stages](https://github.com/tc39/proposals)). You already have the substrate — `docs/superpowers/specs/` is your RFC folder.
1. Write a design doc: **motivation, threat-model impact, alternatives, migration**.
2. Open it as a PR so the design itself is reviewable and gets discussion.
3. Only after the design merges do you write the implementation plan and code.
4. Track shipping status: `proposed → accepted → implemented → released`.

### A public roadmap
Use a **[GitHub Project board](https://github.com/features/issues)** or a pinned roadmap issue (kubernetes, next.js style) so users see what's coming and stop filing dupes. Tie milestones to your next minor release.

---

## 5. Recurring maintenance hygiene
- **Dependabot / Renovate** for GitHub Actions and base-image bumps (you already did `node24` manually — automate it).
- **Pin Actions to SHAs** for supply-chain safety on a security-sensitive repo.
- **CodeQL / actionlint** in CI; you ship a sandbox, so harden your own pipeline.
- **`SECURITY.md`** (present) — keep the private reporting path and threat model current; it's the document users will judge this project by.
- **Two-maintainer rule eventually:** a security-focused tool with a single point of failure is a risk users notice. Document a co-maintainer onboarding path in `CONTRIBUTING.md` when ready.

---

## TL;DR cadence
| Rhythm | Action |
| --- | --- |
| Per PR | CI green · changelog entry under `Unreleased` · squash-merge |
| Weekly | Triage new issues, label, request repros, clear stale |
| Per feature | Issue → (RFC doc if it touches the sandbox) → plan → code |
| Per release | Finalize changelog → tag → verify GHCR image → GitHub Release → smoke test |
