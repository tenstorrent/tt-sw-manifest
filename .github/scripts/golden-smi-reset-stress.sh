#!/usr/bin/env bash
# Run tt-smi PCI reset stress (10x) via UMD using the installer-provided Python env.
# Same reset path as tt-smi -r (default: use_umd, not --use_luwen).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_DIR="${VENV_DIR:-${HOME}/.tenstorrent-venv}"
NUM_RESETS="${NUM_RESETS:-10}"

if [[ -f "${VENV_DIR}/bin/activate" ]]; then
  # shellcheck source=/dev/null
  source "${VENV_DIR}/bin/activate"
elif ! python3 -c "import tt_smi" 2>/dev/null; then
  echo "tt-smi Python package not found (set VENV_DIR to installer venv)" >&2
  exit 1
fi

export NUM_RESETS
echo "=== tt-smi PCI reset stress (${NUM_RESETS} iterations) ==="
exec python3 "${SCRIPT_DIR}/golden-smi-reset-stress.py"
