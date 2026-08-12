#!/usr/bin/env bash
# SMI snapshot test: run `tt-smi -s` using the installer venv and print to stdout.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
GOLDEN_JSON="${GOLDEN_JSON:-${REPO_ROOT}/golden.json}"

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

VENV_DIR="$(_resolve_installer_venv_dir)"
if [[ ! -x "${VENV_DIR}/bin/tt-smi" ]]; then
  echo "Installer venv not found at ${VENV_DIR}" >&2
  exit 1
fi
export VENV_DIR
export PATH="${VENV_DIR}/bin:${PATH}"

printf '\n========== SMI snapshot (tt-smi -s) ==========\n'
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
echo "  command: tt-smi -s"
echo "  tt-smi:  $(tt-smi -v 2>&1 | head -n1)"
echo "  venv:    ${VENV_DIR}"
echo ""

echo "--- tt-smi -s ---"
tt-smi -s
echo ""
echo "PASS: tt-smi -s"
