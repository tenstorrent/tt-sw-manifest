#!/usr/bin/env bash
# Reset stress: run tt-smi reset NUM_RESETS times using the installer venv.
# Default is `tt-smi -r`. Galaxy hosts use `tt-smi -glx_reset`.
#
# Override with:
#   SMI_RESET_MODE=pci|glx
#   SMI_RESET_ARGS='-glx_reset'   # raw args after tt-smi (wins over MODE)
# Or set GOLDEN_RUNNER_LABEL / GITHUB_RUNNER_NAME to a galaxy label (bh-galaxy*).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
GOLDEN_JSON="${GOLDEN_JSON:-${REPO_ROOT}/golden.json}"
NUM_RESETS="${NUM_RESETS:-10}"
RUNNER_LABEL="${GOLDEN_RUNNER_LABEL:-${GITHUB_RUNNER_NAME:-}}"

_resolve_installer_venv_dir() {
  if [[ -n "${VENV_DIR:-}" ]]; then
    printf '%s\n' "${VENV_DIR}"
    return 0
  fi
  if [[ -f /tmp/tenstorrent-installer-venv.path ]]; then
    cat /tmp/tenstorrent-installer-venv.path
    return 0
  fi
  if [[ "${EUID}" -eq 0 && -f /root/.tenstorrent-venv/bin/tt-smi ]]; then
    printf '%s\n' /root/.tenstorrent-venv
    return 0
  fi
  printf '%s\n' "${HOME}/.tenstorrent-venv"
}

resolve_reset_args() {
  # Explicit args win (e.g. SMI_RESET_ARGS='-glx_reset').
  if [[ -n "${SMI_RESET_ARGS:-}" ]]; then
    printf '%s\n' "${SMI_RESET_ARGS}"
    return 0
  fi

  local mode="${SMI_RESET_MODE:-}"
  if [[ -z "${mode}" ]]; then
    case "${RUNNER_LABEL}" in
      bh-galaxy* | *-bh-galaxy* | *galaxy*) mode=glx ;;
      *) mode=pci ;;
    esac
  fi

  case "${mode}" in
    glx | galaxy | galaxy_6u)
      printf '%s\n' "-glx_reset"
      ;;
    pci | r | default)
      printf '%s\n' "-r"
      ;;
    *)
      echo "FAIL: unknown SMI_RESET_MODE='${mode}' (use pci or glx)." >&2
      return 1
      ;;
  esac
}

VENV_DIR="$(_resolve_installer_venv_dir)"
if [[ ! -x "${VENV_DIR}/bin/tt-smi" ]]; then
  echo "Installer venv not found at ${VENV_DIR}" >&2
  exit 1
fi
export VENV_DIR
export PATH="${VENV_DIR}/bin:${PATH}"

RESET_ARGS="$(resolve_reset_args)"
# shellcheck disable=SC2206
RESET_ARGV=( ${RESET_ARGS} )
RESET_LABEL="tt-smi ${RESET_ARGS}"

printf '\n========== Reset test (%s) ==========\n' "${RESET_LABEL}"
if [[ -f "${GOLDEN_JSON}" ]] && command -v jq >/dev/null 2>&1; then
  echo "golden.json pins:"
  jq -r '
    "  installer:     \(.installer)",
    "  kmd:           \(.kmd)",
    "  smi:           \(.smi)",
    "  flash:         \(.flash)",
    "  firmware:      \(.firmware)"
  ' "${GOLDEN_JSON}"
fi
echo "running:"
echo "  command: ${RESET_LABEL} (×${NUM_RESETS})"
echo "  mode:    ${SMI_RESET_MODE:-auto}"
echo "  runner:  ${RUNNER_LABEL:-n/a}"
echo "  tt-smi:  $(tt-smi -v 2>&1 | head -n1)"
echo "  venv:    ${VENV_DIR}"
echo ""

for ((attempt = 1; attempt <= NUM_RESETS; attempt++)); do
  echo "--- ${RESET_LABEL} (${attempt}/${NUM_RESETS}) ---"
  tt-smi "${RESET_ARGV[@]}"
  echo "PASS: reset ${attempt}/${NUM_RESETS}"
done

echo "PASS: ${NUM_RESETS} consecutive resets succeeded (${RESET_LABEL})"
