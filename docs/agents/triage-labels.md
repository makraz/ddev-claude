# Triage Labels

The skills speak in terms of five canonical triage roles. This file maps those roles to the actual label strings used in this repo's issue tracker.

| Label in mattpocock/skills | Label in our tracker | Meaning                                  |
| -------------------------- | -------------------- | ---------------------------------------- |
| `needs-triage`             | `needs-triage`       | Maintainer needs to evaluate this issue  |
| `needs-info`               | `needs-info`         | Waiting on reporter for more information |
| `ready-for-agent`          | `ready-for-agent`    | Fully specified, ready for an AFK agent  |
| `ready-for-human`          | `ready-for-human`    | Requires human implementation            |
| `wontfix`                  | `wontfix`            | Will not be actioned                     |

When a skill mentions a role (e.g. "apply the AFK-ready triage label"), use the corresponding label string from this table.

## This repo

`.github/labels.sh` is the source of truth for the full label set — an idempotent
`gh`-driven sync. All five roles above are defined there. Add or rename a label
there, not ad hoc via `gh label create`, then re-run the script.

`needs-repro` is **not** one of the five. It stays the narrower maintainer label it
already was — "waiting on a reproduction", and chased by the stale bot
(`.github/workflows/stale.yml`). `needs-info` is the general case; reach for
`needs-repro` only when a reproduction specifically is what's missing.

Edit the right-hand column above to match whatever vocabulary you actually use.
