#!/usr/bin/env bash
# Install kmd / tt-smi / tt-flash from golden.json on a self-hosted HW runner.
# Run as root (e.g. sudo bash golden-install-hw.sh). Pattern: tt-installer test-hosted-n150.yml.
set -euo pipefail

GOLDEN_JSON="${GOLDEN_JSON:-/workspace/golden.json}"
INSTALLER_URL="${INSTALLER_URL:-}"

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root (sudo) on hardware runners." >&2
  exit 1
fi

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

echo "=== Golden install (hardware runner) ==="
echo "golden.json: ${GOLDEN_JSON}"
echo "installer:   v${INSTALLER_VER} (${INSTALLER_URL})"
echo "kmd:         ${KMD_VER}"
echo "smi:         ${SMI_VER}"
echo "flash:       ${FLASH_VER}"
echo "firmware:    ${FW_VER} (flash disabled in CI)"

curl -fsSL "${INSTALLER_URL}" -o /tmp/tt-install.sh
chmod +x /tmp/tt-install.sh

# Same pinned components as no-hw CI; skip containers/firmware flash on shared runners.
timeout 1800 bash /tmp/tt-install.sh \
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

echo "=== Hardware install finished ==="
