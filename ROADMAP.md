# Roadmap

Ordering principle: **ship what users are already missing before adding anything new.** Three
stable-worthy releases have accumulated in pre-release limbo while `ddev add-on get` served
`v0.2.0`, so the first job is delivery, not features.

Dates are deliberately absent — this is ordered, not scheduled.

---

## v0.4.0 — stable (next)

Promote the v0.4.0 work to a stable release so users actually receive it. Everything below is
already built and verified; the release itself is the deliverable.

- Mutagen volume mount (~430× on file-heavy work, measured as the agent)
- Tool and plugin curation via `tools:` / `plugins:`
- State in a Docker volume, seeded once from `.ddev/.claude/`
- uid remap to the host user — the thing that makes the volume mount usable at all
- `python` / `node` extras
- Fixes: port-53 egress narrowing, root PATH hijack, `settings.json` clobbering,
  `ddev add-on remove` never deleting its files, `ddev claude exec` stdout pollution

**Gate:** CI green on `main`; a real `ddev add-on get` install verified on a project that was not
used for development.

**This release supersedes v0.3.0-beta.\*** — those never reached users, and their content is
included here. No separate v0.3.0 stable is needed.

---

## v0.4.1 — artifact integrity and the test blind spot

Two things belong here, and the first outranks everything else in this document.

### Artifact integrity — mostly done

Landed: the agent version is pinned via `ARG CLAUDE_VERSION` and the build fails if the installed
version does not match; one resolved version feeds both architectures (previously each arch ran
the installer independently, so a mid-build upstream release could put two versions under one
manifest while the OCI label described neither); and the build emits `provenance: mode=max` plus
an SBOM.

Remaining:

- **Sign release tags** — needs a signing key on the maintainer's machine.
- **Protect `main`**: require the `tests` check, disallow force-push, require a PR. It is currently
  unprotected and was force-pushed during this release with nothing to stop it.
- Put the resolved agent version in the release notes, not only in an OCI label.

### Close the test blind spot

The uid lockout was found by hand, on a real project, after eleven task reviews and a full green
suite. CI could not have caught it: it runs Linux-only, where `performance_mode` resolves to
`bind`, and a bind mount masks uid mismatches entirely.


- **macOS runner in CI**, exercising the Mutagen path. This is the one that matters.
- **DDEV version matrix** — the oldest version the constraint claims (`v1.24.0`) plus latest.
- Make the two network-dependent integration tests resilient, or point them at a host the suite
  controls.
- Narrow ICMP echo by destination — same class as the port-53 hole, still open.
- The dnsmasq `pkill`-then-restart race: logs `Address already in use`, recovers silently.
- Restore a tracked maintainer playbook (see *Debt* below).

## v0.5.0 — extras and ergonomics

Only after the pipeline is trustworthy.

- Extras catalogue: `gh`, `playwright`, `node` LTS beyond Debian's 18.x
- `ddev claude doctor` — one command reporting mount mode, agent uid, firewall state, sync status,
  and whether the agent can actually read the project. Every hard bug in v0.4.0 would have been a
  one-line diagnosis with this.
- Per-project `CLAUDE.md` scaffolding
- Reduce the `chown -R /home/claude` cost on every macOS start

## v1.0.0 — the compatibility promise

1.0 means the config surface is stable and breaks require a major bump. Prerequisites:

- `.ddev/claude.yaml` schema settled — no new keys for one full minor cycle
- CI covering both mount modes on both host families
- The security model documented with its limits stated (largely done — `SECURITY.md` names the
  residual holes rather than hiding them)
- A real deprecation path for config keys
- Someone other than the author has installed it from scratch and reported back

---

## Debt to clear regardless of version

- **The release process is no longer documented in-tree.** `docs/` was untracked deliberately;
  `docs/MAINTAINING.md` and `docs/MAINTAINER.md` went with it, and the release procedure now lives
  only in `RELEASING.md` (new) and one issue template. If `docs/` stays untracked, maintainer
  documentation belongs at the repo root, not in it.
- **`main` must never fall behind a release again.** It was 12 commits behind for two months, with
  scheduled CI failing on code nobody was developing against.
- **The `pre-*` backup tags** (`pre-drop-docs-*`, `pre-rewrite-*`) are local-only leftovers from
  history rewrites and now point at rewritten commits. They are not a recovery path. Delete them.
- **`chore/maintainer-tooling` can be deleted** once v0.4.0 merges — its content is in `main`, and
  its two unpushed cherry-picks arrive via the v0.4.0 branch.
- **Two integration tests reach the public internet.** Flaky by construction.
- **No upgrade guidance for breaking releases.** v0.4.0 changes defaults, moves state and changes
  the container's user identity. The changelog says what changed; nothing tells an existing user
  what to *do* about it. A short "upgrading from v0.2.x" section would carry more weight than any
  feature in v0.5.0.
- **No deprecation policy.** Required before 1.0 can mean anything.

---

## Deliberately not planned

- Publishing to Packagist. There is no PHP in this repo; `ddev add-on get` is the distribution
  channel.
- Per-extra image variants. Combinatorial, and extras are cheap per-project build layers.
- Making the tool allow-list a security boundary. It cannot be one — the shim runs as the agent's
  own uid, and `Bash` grants equivalent capability. It is a default and a cost control, and
  `README.md` says so.
