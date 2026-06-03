#!/usr/bin/env bash
# Install kmd / tt-smi / tt-flash / tt-metalium from golden.json on a self-hosted HW runner.
# Run as root (e.g. sudo bash golden-install-hw.sh). Pattern: tt-installer test-hosted-n150.yml.
#
# Image pulls:
#   - tt-installer pulls tt-metalium-ubuntu-22.04-release-amd64 (metal-version) only.
#   - This script additionally pulls upstream-tests-bh (same metal-version) for golden CI upstream step.
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=golden-metal-images.sh
source "${SCRIPT_DIR}/golden-metal-images.sh"

INSTALLER_VER="$(jq -r '.installer' "${GOLDEN_JSON}")"
KMD_VER="$(jq -r '.kmd' "${GOLDEN_JSON}")"
SMI_VER="$(jq -r '.smi' "${GOLDEN_JSON}")"
FLASH_VER="$(jq -r '.flash' "${GOLDEN_JSON}")"
FW_VER="$(jq -r '.firmware' "${GOLDEN_JSON}")"
METAL_VERSION="$(normalize_metal_image_tag "$(read_golden_metal_version "${GOLDEN_JSON}")")"
METAL_UPSTREAM_IMAGE="$(resolve_metal_upstream_image "${GOLDEN_JSON}")"
METALIUM_RELEASE_IMAGE="$(resolve_metalium_release_image "${GOLDEN_JSON}")"

CONTAINER_RUNTIME="docker"
if command -v docker >/dev/null 2>&1; then
  CONTAINER_RUNTIME="docker"
elif command -v podman >/dev/null 2>&1; then
  CONTAINER_RUNTIME="podman"
else
  echo "WARNING: neither docker nor podman found; metalium container install may fail" >&2
  CONTAINER_RUNTIME="docker"
fi

if [[ -z "${INSTALLER_URL}" ]]; then
  INSTALLER_URL="https://github.com/tenstorrent/tt-installer/releases/download/v${INSTALLER_VER}/install.sh"
fi

echo "=== Golden install (hardware runner) ==="
echo "golden.json: ${GOLDEN_JSON}"
echo "installer:   v${INSTALLER_VER} (${INSTALLER_URL})"
echo "kmd:         ${KMD_VER}"
echo "smi:         ${SMI_VER}"
echo "flash:       ${FLASH_VER}"
echo "firmware:    ${FW_VER}"
echo "metal-version: ${METAL_VERSION}"
echo "  release:   ${METALIUM_RELEASE_IMAGE} (installer)"
echo "  upstream:  ${METAL_UPSTREAM_IMAGE} (golden CI only, not installer)"

curl -fsSL "${INSTALLER_URL}" -o /tmp/tt-install.sh
chmod +x /tmp/tt-install.sh

timeout 1800 bash /tmp/tt-install.sh \
  --mode-non-interactive \
  --install-kmd \
  --no-install-hugepages \
  --update-firmware on \
  --install-metalium-container \
  --no-install-metalium-models-container \
  --no-install-forge-container \
  --no-install-sfpi \
  --no-install-inference-server \
  --no-install-studio \
  --install-container-runtime "${CONTAINER_RUNTIME}" \
  --python-choice new-venv \
  --reboot-option never \
  --kmd-version "${KMD_VER}" \
  --smi-version "${SMI_VER}" \
  --flash-version "${FLASH_VER}" \
  --fw-version "${FW_VER}" \
  --metalium-image-tag "${METAL_VERSION}"

INSTALLER_VENV="${HOME}/.tenstorrent-venv"
if [[ -x "${INSTALLER_VENV}/bin/python" ]]; then
  echo "${INSTALLER_VENV}" > /tmp/tenstorrent-installer-venv.path
  echo "Installer Python venv recorded at ${INSTALLER_VENV}"
else
  echo "WARNING: expected installer venv not found at ${INSTALLER_VENV}/bin/python" >&2
fi

TT_METALIUM_WRAPPER="${HOME}/.local/bin/tt-metalium"
if [[ -x "${TT_METALIUM_WRAPPER}" ]]; then
  grep -E '^METALIUM_IMAGE=' "${TT_METALIUM_WRAPPER}" | head -n1 | cut -d= -f2- | tr -d '"' \
    > /tmp/tenstorrent-metalium-image.path || true
  echo "Installer tt-metalium image: $(cat /tmp/tenstorrent-metalium-image.path 2>/dev/null || echo unknown)"
fi

echo "Pulling upstream-tests-bh (golden metal upstream step; not part of tt-installer)..."
if ${CONTAINER_RUNTIME} pull "${METAL_UPSTREAM_IMAGE}"; then
  echo "${METAL_UPSTREAM_IMAGE}" > /tmp/tenstorrent-metal-upstream-image.path
else
  echo "WARNING: failed to pull ${METAL_UPSTREAM_IMAGE}; upstream step will retry pull" >&2
  echo "${METAL_UPSTREAM_IMAGE}" > /tmp/tenstorrent-metal-upstream-image.path
fi

echo "=== Hardware install finished ==="
