# Security Policy

## Why this add-on has a security policy

`ddev-claude` runs Claude Code with `--dangerously-skip-permissions` ("YOLO mode")
by default. The only thing standing between an off-the-rails agent and your
secrets is the **outbound firewall** (`iptables` + `ipset` + `dnsmasq`) built into
the sidecar container. The security promise is:

> An agent running in the sidecar cannot exfiltrate data to an arbitrary
> destination, and cannot reach anything outside the project tree and the
> explicitly allow-listed domains.

## What the firewall does NOT protect against

The firewall bounds **where** traffic can go, not **what** leaves through the
destinations you allow. Read this before trusting the sandbox with secrets:

- **DNS tunnelling through an allowed resolver is still possible.** As of v0.4.0 port
  53 egress is restricted by destination — only the configured DNS upstreams (Docker's
  embedded resolver, the host gateway, `1.1.1.1`, `8.8.8.8`) are reachable, so a raw
  socket to `attacker:53` is blocked. What remains is inherent to permitting any
  recursive resolver: an agent can encode data into queries for a domain whose
  authoritative nameserver an attacker controls, and read data back out of the answers.
  Demonstrated in review. Restricting this further would mean giving up recursive DNS.

- **ICMP echo is unrestricted by destination.** The OUTPUT chain accepts
  `--icmp-type echo-request` to any host, and ICMP payloads carry data, so a
  low-bandwidth tunnel to an arbitrary host is constructible. Same class as the
  port-53 hole that v0.4.0 closed, and not yet narrowed — it needs its own change and
  test cycle. Tracked.

- **Host-side code execution through the project tree is in scope for the agent.**
  "Sandbox escape" below means writing *outside* the mounted project — but inside
  it, the agent can write `.git/hooks/*` (run on the host by your next git
  command), `.ddev/commands/host/*` (run on the host by your next `ddev` command),
  and `.ddev/claude.local/Dockerfile.fragment` (root `RUN` lines in the next image
  build). All three predate v0.4.0. One v0.4.0 nuance: because the agent now runs
  as *your* uid, files it plants are owned by you rather than by a mismatched
  container uid, so they look native. Review agent-authored changes to `.git/` and
  `.ddev/` with the same care as any other code you are about to execute.

- **Exfiltration through allow-listed hosts is still possible.** The default
  allow-list includes `github.com`/`api.github.com`, and the sidecar carries the
  agent's own `GITHUB_PERSONAL_ACCESS_TOKEN`/`GH_TOKEN` and `ANTHROPIC_API_KEY`.
  A compromised or adversarial agent can push the project to a repo, create a
  gist, or open an issue/PR — all over an *allowed* channel. The firewall stops
  egress to *unknown* hosts; it does **not** stop a determined agent from sending
  data to a host you have allowed. **Treat the firewall as a guard against
  accidental/casual egress, not as a barrier against a determined exfiltrator.**
  The fewer domains you allow-list (and the more narrowly scoped your tokens),
  the smaller this channel.
- **IP-based allow-listing is coarse on shared CDNs.** Allow-listing is by
  resolved IP. When an allowed domain sits behind a shared CDN edge
  (Fastly/Cloudflare/etc.), other tenants on the same edge IP become reachable
  too. This is inherent to IP-level filtering.
- **Anything the agent can already read, it can act on.** The agent has full
  read/write to the bind-mounted project tree and the tokens in its environment.
  The sandbox is a network boundary, not a data-classification or DLP layer.

Within those limits, a bug that lets traffic reach a host that is **not**
allow-listed — or that escalates privilege or escapes the container — is a real
vulnerability. The categories we care
about most:

- **Firewall escape / bypass** — outbound traffic reaching a host that is not in
  the static allow-list, the `*.domains` contributions, `extra_allowed_domains`,
  or `EXTRA_ALLOWED_DOMAINS`. This includes DNS rebinding, IPv6 leaks, and
  proxy/CONNECT tricks.
- **Sandbox escape** — the agent gaining write access to the host filesystem
  outside the mounted project, or to other DDEV containers it should not reach.
- **Secret exposure** — auth tokens (in the `${DDEV_SITENAME}_claude_state` volume,
  and snapshotted to `.ddev/.claude/.credentials.json` on session exit), `ANTHROPIC_API_KEY`,
  `GITHUB_PERSONAL_ACCESS_TOKEN`/`GH_TOKEN`, or host SSH keys becoming readable
  or exfiltratable from inside the sidecar.
- **Privilege escalation** — the sidecar process gaining root on the host, or the
  build pipeline (`build-image.sh`, extras fragments) executing attacker-controlled
  code outside the intended Dockerfile build.
- **Supply-chain integrity** of the published base image
  `ghcr.io/makraz/ddev-claude-base`.

## Supported versions

Security fixes land on `main` and are released as a new tag. Only the **latest
released version** is supported. Pin with `ddev add-on get makraz/ddev-claude@vX.Y.Z`
and upgrade promptly when a security release is published.

| Version | Supported |
| --- | --- |
| Latest release | ✅ |
| Older releases | ❌ — please upgrade |

## Reporting a vulnerability

**Do not open a public issue, and do not post a proof-of-concept in a public PR
or discussion.**

Report privately through GitHub's
[Private Vulnerability Reporting](https://github.com/makraz/ddev-claude/security/advisories/new)
("Report a vulnerability" under the **Security** tab). This opens a private
advisory only the maintainer can see.

Please include:

- The version (`ddev add-on get` pin or git tag) and your **host OS + architecture**
  (`uname -m`) — firewall behaviour differs across `amd64`/`arm64`.
- `ddev version`.
- A minimal reproduction: the relevant `.ddev/claude.yaml`, any
  `.ddev/claude.local/` escape-hatch content, and the exact commands run.
- For firewall issues: the destination that was reached and the output of
  `ddev claude exec -- sh -c 'cat /etc/claude-firewall/*.list'` plus the
  `init-firewall.sh` log if you have it.
- The impact you believe it has.

## What to expect

- **Acknowledgement** within a few days.
- An assessment of severity and affected versions, discussed with you in the
  private advisory.
- A fix on `main`, a patched release, and a published GitHub Security Advisory
  crediting you (unless you ask to remain anonymous).
- Coordinated disclosure: please give us a reasonable window to ship a fix before
  any public write-up.

## Scope notes

- The **Dockerfile escape hatch** (`.ddev/claude.local/`) and arbitrary
  `extra_allowed_domains` are user-controlled by design. Widening your own
  allow-list or installing your own tools is not a vulnerability — it is the
  documented opt-in. Reports there need to show that the *defaults* or the
  *parsing/build pipeline* can be subverted, not that a user can loosen their own
  sandbox.
- Issues in upstream dependencies (Claude Code, DDEV, Debian packages, GitHub
  Actions) should be reported to those projects; tell us too if `ddev-claude`'s
  configuration makes the impact worse.
