#!/usr/bin/env bash
# Maakt de labels aan die de workflow gebruikt om issues te routeren.
# Vereist: gh CLI, ingelogd (gh auth login), uitvoeren vanuit de repo-map.

set -euo pipefail

declare -A labels=(
  ["architecture"]="5319e7"
  ["bug"]="d73a4a"
  ["feature"]="a2eeef"
  ["ci"]="0e8a16"
  ["dependencies"]="0366d6"
  ["docs"]="0075ca"
  ["needs-refinement"]="fbca04"
  ["needs-info"]="d876e3"
  ["blocked"]="b60205"
  ["program-status"]="006b75"
)

for name in "${!labels[@]}"; do
  color="${labels[$name]}"
  gh label create "$name" --color "$color" --force
  echo "Label '$name' aangemaakt of bijgewerkt."
done
