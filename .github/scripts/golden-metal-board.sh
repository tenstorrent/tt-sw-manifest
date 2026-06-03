#!/usr/bin/env bash
# Shared runner → board profile lookup for golden metal CI scripts.
set -euo pipefail

golden_metal_board_json="${GOLDEN_METAL_BOARDS_JSON:-}"
golden_metal_match_key="${GOLDEN_RUNNER_LABEL:-${GITHUB_RUNNER_NAME:-}}"

golden_metal_require_board() {
  if [[ -z "${golden_metal_board_json}" || ! -f "${golden_metal_board_json}" ]]; then
    echo "board config not found: ${golden_metal_board_json}" >&2
    exit 1
  fi
  if ! command -v jq >/dev/null 2>&1; then
    echo "jq is required" >&2
    exit 1
  fi
  if [[ -z "${golden_metal_match_key}" ]]; then
    echo "GOLDEN_RUNNER_LABEL or GITHUB_RUNNER_NAME must be set" >&2
    exit 1
  fi

  GOLDEN_METAL_BOARD="$(
    jq -c --arg key "${golden_metal_match_key}" '
      [.[]
        | (.["runner-label"] // .runner // "") as $prefix
        | select($prefix != "" and ($key == $prefix or ($key | startswith($prefix))))
      ][0]
    ' "${golden_metal_board_json}"
  )"

  if [[ -z "${GOLDEN_METAL_BOARD}" || "${GOLDEN_METAL_BOARD}" == "null" ]]; then
    echo "No metal board profile for runner label '${golden_metal_match_key}' in ${golden_metal_board_json}" >&2
    exit 1
  fi
}

golden_metal_board_bool() {
  local field="$1"
  local default="${2:-false}"
  jq -r --arg f "${field}" --arg d "${default}" '
    if .[$f] == null then $d else (.[$f] | tostring) end
  ' <<<"${GOLDEN_METAL_BOARD}"
}
