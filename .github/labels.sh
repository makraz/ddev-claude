#!/usr/bin/env bash
# Idempotent label sync for ddev-claude. Requires the `gh` CLI, authenticated.
#
#   ./.github/labels.sh                 # sync to the current repo (origin)
#   REPO=makraz/ddev-claude ./.github/labels.sh
#
# Re-runnable: creates missing labels, updates color/description on existing ones.
set -euo pipefail

REPO="${REPO:-$(gh repo view --json nameWithOwner -q .nameWithOwner)}"

# name|color|description  (color = 6-hex, no leading #)
LABELS=(
  # Type
  "bug|d73a4a|Something isn't working"
  "enhancement|a2eeef|New feature or request"
  "question|d876e3|Further information is requested"
  "docs|0075ca|Documentation only"
  "security|b60205|Security-sensitive; handle via private advisory when applicable"
  # Status
  "needs-triage|ededed|Awaiting maintainer triage"
  "needs-repro|fbca04|Waiting on a reproduction (chased by the stale bot)"
  "confirmed|0e8a16|Reproduced / accepted"
  "blocked|b60205|Blocked on something else"
  "wontfix|ffffff|This will not be worked on"
  "stale|795548|No recent activity"
  # Contribution
  "good first issue|7057ff|Good for newcomers"
  "help wanted|008672|Extra attention is wanted"
  # Area
  "area/firewall|5319e7|Sandbox firewall / network policy"
  "area/image|5319e7|Base image / Dockerfile"
  "area/extras|5319e7|Extras catalog"
  "area/ci|5319e7|CI / GitHub Actions"
  # Meta
  "dependencies|0366d6|Dependency updates (Dependabot)"
  "release|c5def5|Release tracking"
  "pinned|fef2c0|Exempt from the stale bot"
)

echo "Syncing ${#LABELS[@]} labels to $REPO"
for entry in "${LABELS[@]}"; do
  IFS='|' read -r name color desc <<<"$entry"
  if gh label create "$name" --color "$color" --description "$desc" --repo "$REPO" >/dev/null 2>&1; then
    echo "  + created  $name"
  else
    gh label edit "$name" --color "$color" --description "$desc" --repo "$REPO" >/dev/null
    echo "  ~ updated  $name"
  fi
done
echo "Done."
