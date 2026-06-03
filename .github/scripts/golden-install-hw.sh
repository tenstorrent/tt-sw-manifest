#!/usr/bin/env bash
# Install kmd / tt-smi / tt-flash / tt-metalium from golden.json on a self-hosted HW runner.
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
METALIUM_TAG="$(jq -r '.["metalium-image-tag"]' "${GOLDEN_JSON}")"
METAL_UPSTREAM_IMAGE="$(jq -r '.["metal-upstream-image"] // empty' "${GOLDEN_JSON}")"
if [[ -z "${METAL_UPSTREAM_IMAGE}" || "${METAL_UPSTREAM_IMAGE}" == "null" ]]; then
  METAL_UPSTREAM_IMAGE="ghcr.io/tenstorrent/tt-metal/upstream-tests-bh:${METALIUM_TAG}"
fi

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
echo "metalium:    ${METALIUM_TAG} (tt-metalium container via installer)"
echo "metal tests: ${METAL_UPSTREAM_IMAGE} (pulled after install for upstream CI)"

curl -fsSL "${INSTALLER_URL}" -o /tmp/tt-install.sh
chmod +x /tmp/tt-install.sh

# Customer-style stack: installer pins versions, pulls tt-metalium, flashes firmware once.
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
  --metalium-image-tag "${METALIUM_TAG}"

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

echo "Pulling metal upstream test image (same tag family as golden.json)..."
if ${CONTAINER_RUNTIME} pull "${METAL_UPSTREAM_IMAGE}"; then
  echo "${METAL_UPSTREAM_IMAGE}" > /tmp/tenstorrent-metal-upstream-image.path
else
  echo "WARNING: failed to pull ${METAL_UPSTREAM_IMAGE}; metal upstream step may retry pull" >&2
  echo "${METAL_UPSTREAM_IMAGE}" > /tmp/tenstorrent-metal-upstream-image.path
fi

echo "=== Hardware install finished ==="
