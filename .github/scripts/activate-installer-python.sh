#!/usr/bin/env bash
# Source from CI scripts to use tt-smi/tt-flash from the venv created by tt-installer (--python-choice new-venv).
# Prepends the venv to PATH (works under sudo, which ignores `source activate` for command lookup).
set -euo pipefail

_resolve_installer_venv_dir() {
  if [[ -n "${VENV_DIR:-}" ]]; then
    printf '%s\n' "${VENV_DIR}"
    return 0
  fi

  if [[ -f /tmp/tenstorrent-installer-venv.path ]]; then
    cat /tmp/tenstorrent-installer-venv.path
    return 0
  fi

  local ttis_file="${TTIS_FILE:-}"
  if [[ -z "${ttis_file}" ]]; then
    for candidate in "${HOME}/.ttis" "/root/.ttis"; do
      if [[ -f "${candidate}" ]] && command -v jq >/dev/null 2>&1; then
        ttis_file="${candidate}"
        break
      fi
    done
  fi
  if [[ -n "${ttis_file}" && -f "${ttis_file}" ]] && command -v jq >/dev/null 2>&1; then
    local from_ttis
    from_ttis="$(jq -r '.python_env.location // empty' "${ttis_file}" 2>/dev/null || true)"
    if [[ -n "${from_ttis}" && "${from_ttis}" != "null" ]]; then
      printf '%s\n' "${from_ttis}"
      return 0
    fi
  fi

  if [[ "${EUID}" -eq 0 && -f /root/.tenstorrent-venv/bin/tt-smi ]]; then
    printf '%s\n' /root/.tenstorrent-venv
    return 0
  fi

  printf '%s\n' "${HOME}/.tenstorrent-venv"
}

VENV_DIR="$(_resolve_installer_venv_dir)"

if [[ ! -x "${VENV_DIR}/bin/tt-smi" ]]; then
  echo "Installer venv not found at ${VENV_DIR} (expected ${VENV_DIR}/bin/tt-smi)" >&2
  echo "Run tt-installer with --python-choice new-venv or set VENV_DIR." >&2
  exit 1
fi

export VENV_DIR
export PATH="${VENV_DIR}/bin:${PATH}"

echo "Using installer env: ${VENV_DIR} ($(tt-smi -v 2>&1 | head -n1))"
