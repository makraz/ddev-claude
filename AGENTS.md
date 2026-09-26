# AGENTS.md

Guidance for coding agents working in this repository. This file is the source of
truth for every agent tool; `CLAUDE.md` points here.

## Agent skills

### Issue tracker

Issues live in GitHub Issues on `makraz/ddev-claude`, driven via the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

The five canonical triage roles use their canonical names; `.github/labels.sh` is the source of truth for the full label set. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: `CONTEXT.md` at the root, ADRs in `docs/adr/` (neither exists yet; created lazily). See `docs/agents/domain.md`.
