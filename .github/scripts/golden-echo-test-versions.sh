#!/usr/bin/env bash
# Print pinned / runtime versions at the start of a golden HW test step.
set -euo pipefail

golden_echo_test_banner() {
  printf '\n========== %s ==========\n' "$1"
}

golden_echo_golden_json_pins() {
  local golden_json="${1:?}"
  if [[ ! -f "${golden_json}" ]] || ! command -v jq >/dev/null 2>&1; then
    return 0
  fi
  echo "golden.json pins:"
  jq -r '
    "  installer:     \(.installer)",
    "  kmd:           \(.kmd)",
    "  smi:           \(.smi)",
    "  flash:         \(.flash)",
    "  firmware:      \(.firmware)",
    "  metal-version: \(.["metal-version"] // .["metalium-image-tag"] // "n/a")",
    "  metal-upstream-tag: \(.["metal-upstream-tag"] // "(not set)")"
  ' "${golden_json}"
}
