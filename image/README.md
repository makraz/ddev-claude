# ddev-claude base image

Source of the pre-built sidecar image published to
`ghcr.io/makraz/ddev-claude-base:<tag>`.

## What's inside

- `debian:bookworm-slim` base
- `ca-certificates curl git bash sudo iptables ipset dnsmasq dnsutils iproute2`
- An unprivileged `claude` user (uid 1000) with a NOPASSWD sudoers entry
  scoped to `/usr/local/bin/init-firewall.sh`
- The Claude Code native binary at `/home/claude/.local/bin/claude`

## What's NOT inside

- `init-firewall.sh` — copied in by the addon's per-project wrapper
  (`claude/Dockerfile.base`), because it changes more often than this image.
- Any extras (PHP, gh, Playwright, etc.) — those install per project via
  the catalog at `claude/extras/` and the escape hatch
  `.ddev/claude.local/Dockerfile.fragment`.

## Versioning

The image tag equals the addon's git tag, 1:1. There is **no `:latest`** —
consumers pin to a specific addon version, which pins to a specific image.

The Claude Code binary version baked into each image is recorded in the OCI
label `io.makraz.ddev-claude.claude-version`. Inspect with:

```bash
docker inspect ghcr.io/makraz/ddev-claude-base:v0.3.0 \
  --format '{{ index .Config.Labels "io.makraz.ddev-claude.claude-version" }}'
```

## Building locally

```bash
docker build -t ghcr.io/makraz/ddev-claude-base:v0.3.0 image/
```

Docker's default pull policy is `missing`, so a local image with the same tag
takes precedence over the published one. Useful for iterating on
`image/Dockerfile` without publishing.
