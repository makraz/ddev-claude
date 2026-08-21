<!--
  Security fix? Do not describe the vulnerability here — coordinate privately first
  via SECURITY.md, then reference the advisory.
-->

## Why

<!-- The problem this solves. Link the issue: Closes #123 -->

## What changed

<!-- Summary of the change. -->

## Testing

- [ ] `bats tests/` passes locally
- [ ] Manually ran `ddev claude` / `ddev claude shell` in a scratch project
- Host OS / arch tested on: <!-- e.g. macOS arm64, Ubuntu amd64 -->

## Checklist

- [ ] Conventional Commit title (`feat:` / `fix:` / `docs:` / `ci:` / `chore:`)
- [ ] Added an entry under `## [Unreleased]` in `CHANGELOG.md`
- [ ] New/changed extra: updated `README.md` and added a `tests/build-image.bats` case
- [ ] No firewall allow-list widened beyond what the change strictly needs
