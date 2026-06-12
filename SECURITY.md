# Security Policy

## Why this add-on has a security policy

`ddev-claude` runs Claude Code with `--dangerously-skip-permissions` ("YOLO mode")
by default. The only thing standing between an off-the-rails agent and your
secrets is the **outbound firewall** (`iptables` + `ipset` + `dnsmasq`) built into
the sidecar container. The security promise is:

> An agent running in the sidecar cannot exfiltrate data to an arbitrary
> destination, and cannot reach anything outside the project tree and the
> explicitly allow-listed domains.

A bug that breaks that promise is a real vulnerability. The categories we care
about most:

- **Firewall escape / bypass** — outbound traffic reaching a host that is not in
  the static allow-list, the `*.domains` contributions, `extra_allowed_domains`,
  or `EXTRA_ALLOWED_DOMAINS`. This includes DNS rebinding, IPv6 leaks, and
  proxy/CONNECT tricks.
- **Sandbox escape** — the agent gaining write access to the host filesystem
  outside the mounted project, or to other DDEV containers it should not reach.
- **Secret exposure** — `.ddev/.claude/` auth tokens, `ANTHROPIC_API_KEY`,
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
