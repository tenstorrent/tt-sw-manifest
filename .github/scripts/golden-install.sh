#!/usr/bin/env bash
# Install kmd / tt-smi / tt-flash using tt-installer at the version pinned in golden.json.
# Intended for CI without Tenstorrent hardware (no firmware flash, no metalium pull).
set -euo pipefail

GOLDEN_JSON="${GOLDEN_JSON:-/workspace/golden.json}"
INSTALLER_URL="${INSTALLER_URL:-}"

if [[ ! -f "${GOLDEN_JSON}" ]]; then
  echo "golden.json not found at ${GOLDEN_JSON}" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required" >&2
  exit 1
fi

INSTALLER_VER="$(jq -r '.installer' "${GOLDEN_JSON}")"
KMD_VER="$(jq -r '.kmd' "${GOLDEN_JSON}")"
SMI_VER="$(jq -r '.smi' "${GOLDEN_JSON}")"
FLASH_VER="$(jq -r '.flash' "${GOLDEN_JSON}")"
FW_VER="$(jq -r '.firmware' "${GOLDEN_JSON}")"

if [[ -z "${INSTALLER_URL}" ]]; then
  INSTALLER_URL="https://github.com/tenstorrent/tt-installer/releases/download/v${INSTALLER_VER}/install.sh"
fi

echo "=== Golden install (no hardware) ==="
echo "golden.json: ${GOLDEN_JSON}"
echo "installer:   v${INSTALLER_VER} (${INSTALLER_URL})"
echo "kmd:         ${KMD_VER}"
echo "smi:         ${SMI_VER}"
echo "flash:       ${FLASH_VER}"
echo "firmware:    ${FW_VER} (pinned; flash step disabled in CI)"

curl -fsSL "${INSTALLER_URL}" -o /tmp/tt-install.sh
chmod +x /tmp/tt-install.sh

# Mirror tt-installer/.github/workflows/test-debian-ubuntu.yml (container, non-interactive).
# Boolean options use --no-install-* / --install-* (not --install-*=off); see install.sh --help.
timeout 900 bash /tmp/tt-install.sh \
  --mode-non-interactive \
  --install-kmd \
  --no-install-hugepages \
  --update-firmware off \
  --no-install-metalium-container \
  --no-install-metalium-models-container \
  --no-install-forge-container \
  --no-install-sfpi \
  --no-install-inference-server \
  --no-install-studio \
  --install-container-runtime no \
  --python-choice new-venv \
  --reboot-option never \
  --kmd-version "${KMD_VER}" \
  --smi-version "${SMI_VER}" \
  --flash-version "${FLASH_VER}" \
  --fw-version "${FW_VER}"

INSTALLER_VENV="${HOME}/.tenstorrent-venv"
if [[ -x "${INSTALLER_VENV}/bin/python" ]]; then
  echo "${INSTALLER_VENV}" > /tmp/tenstorrent-installer-venv.path
  echo "Installer Python venv recorded at ${INSTALLER_VENV}"
fi

echo "=== Install finished ==="
