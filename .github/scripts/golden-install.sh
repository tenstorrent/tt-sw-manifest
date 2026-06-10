#!/usr/bin/env bash
# Install kmd / tt-smi / tt-flash (and optionally metalium) via tt-installer at golden.json pins.
#
# Usage:
#   golden-install.sh [--hw] [--force-flash]
#
#   --hw           Hardware runner: hugepages, metalium container, container runtime,
#                  upstream-tests-bh pull. Requires root.
#   --force-flash  Flash firmware during install (default: off).
set -euo pipefail

GOLDEN_JSON="${GOLDEN_JSON:-/workspace/golden.json}"
INSTALLER_URL="${INSTALLER_URL:-}"
HW="${GOLDEN_HW:-0}"
FORCE_FLASH="${FORCE_FLASH:-0}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --hw) HW=1; shift ;;
    --force-flash) FORCE_FLASH=1; shift ;;
    -h | --help)
      sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 2
      ;;
  esac
done

if [[ "${HW}" -eq 1 && "${EUID}" -ne 0 ]]; then
  echo "Run as root (sudo) for --hw installs." >&2
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

readonly GOLDEN_METALIUM_RELEASE_REPO="ghcr.io/tenstorrent/tt-metal/tt-metalium-ubuntu-22.04-release-amd64"
readonly GOLDEN_METAL_UPSTREAM_REPO="ghcr.io/tenstorrent/tt-metal/upstream-tests-bh"

normalize_metal_image_tag() {
  local tag="${1:?}"
  case "${tag}" in
    latest-rc | latest) printf '%s\n' "${tag}" ;;
    v*) printf '%s\n' "${tag}" ;;
    *) printf 'v%s\n' "${tag}" ;;
  esac
}

read_golden_metal_version() {
  jq -r '.["metal-version"] // .["metalium-image-tag"] // empty' "${GOLDEN_JSON}"
}

read_golden_metal_upstream_tag() {
  jq -r '.["metal-upstream-tag"] // empty' "${GOLDEN_JSON}"
}

metalium_release_image_ref() {
  printf '%s:%s\n' "${GOLDEN_METALIUM_RELEASE_REPO}" "$(normalize_metal_image_tag "$1")"
}

metal_upstream_image_ref() {
  printf '%s:%s\n' "${GOLDEN_METAL_UPSTREAM_REPO}" "$(normalize_metal_image_tag "$1")"
}

INSTALLER_VER="$(jq -r '.installer' "${GOLDEN_JSON}")"
KMD_VER="$(jq -r '.kmd' "${GOLDEN_JSON}")"
SMI_VER="$(jq -r '.smi' "${GOLDEN_JSON}")"
FLASH_VER="$(jq -r '.flash' "${GOLDEN_JSON}")"
FW_VER="$(jq -r '.firmware' "${GOLDEN_JSON}")"

if [[ -z "${INSTALLER_URL}" ]]; then
  INSTALLER_URL="https://github.com/tenstorrent/tt-installer/releases/download/v${INSTALLER_VER}/install.sh"
fi

if [[ "${FORCE_FLASH}" -eq 1 ]]; then
  FW_UPDATE_FLAG="--update-firmware force"
  FW_NOTE="flash enabled (--force-flash)"
else
  FW_UPDATE_FLAG="--update-firmware off"
  FW_NOTE="flash disabled (default)"
fi

if [[ "${HW}" -eq 1 ]]; then
  METAL_VERSION="$(normalize_metal_image_tag "$(read_golden_metal_version)")"
  METALIUM_RELEASE_IMAGE="$(metalium_release_image_ref "${METAL_VERSION}")"
  METAL_UPSTREAM_TAG="$(read_golden_metal_upstream_tag)"

  CONTAINER_RUNTIME="docker"
  if command -v docker >/dev/null 2>&1; then
    CONTAINER_RUNTIME="docker"
  elif command -v podman >/dev/null 2>&1; then
    CONTAINER_RUNTIME="podman"
  else
    echo "WARNING: neither docker nor podman found; metalium container install may fail" >&2
  fi

  echo "=== Golden install (hardware) ==="
  echo "golden.json: ${GOLDEN_JSON}"
  echo "installer:   v${INSTALLER_VER} (${INSTALLER_URL})"
  echo "kmd:         ${KMD_VER}"
  echo "smi:         ${SMI_VER}"
  echo "flash:       ${FLASH_VER}"
  echo "firmware:    ${FW_VER} (${FW_NOTE})"
  echo "metal-version: ${METAL_VERSION}"
  echo "  release:   ${METALIUM_RELEASE_IMAGE} (installer)"
  if [[ -n "${METAL_UPSTREAM_TAG}" ]]; then
    echo "  upstream:  $(metal_upstream_image_ref "${METAL_UPSTREAM_TAG}") (golden CI only)"
  else
    echo "  upstream:  (skipped — metal-upstream-tag not set)"
  fi

  INSTALL_TIMEOUT=1800
  HUGE_PAGES_FLAG="--install-hugepages"
  METALIUM_FLAG="--install-metalium-container"
  CONTAINER_RUNTIME_FLAG="--install-container-runtime ${CONTAINER_RUNTIME}"
  METALIUM_TAG_FLAG=(--metalium-image-tag "${METAL_VERSION}")
else
  echo "=== Golden install (no hardware) ==="
  echo "golden.json: ${GOLDEN_JSON}"
  echo "installer:   v${INSTALLER_VER} (${INSTALLER_URL})"
  echo "kmd:         ${KMD_VER}"
  echo "smi:         ${SMI_VER}"
  echo "flash:       ${FLASH_VER}"
  echo "firmware:    ${FW_VER} (${FW_NOTE})"

  INSTALL_TIMEOUT=900
  HUGE_PAGES_FLAG="--no-install-hugepages"
  METALIUM_FLAG="--no-install-metalium-container"
  CONTAINER_RUNTIME_FLAG="--install-container-runtime no"
  METALIUM_TAG_FLAG=()
fi

curl -fsSL "${INSTALLER_URL}" -o /tmp/tt-install.sh
chmod +x /tmp/tt-install.sh

timeout "${INSTALL_TIMEOUT}" bash /tmp/tt-install.sh \
  --mode-non-interactive \
  --install-kmd \
  "${HUGE_PAGES_FLAG}" \
  "${FW_UPDATE_FLAG}" \
  "${METALIUM_FLAG}" \
  --no-install-metalium-models-container \
  --no-install-forge-container \
  --no-install-sfpi \
  --no-install-inference-server \
  --no-install-studio \
  ${CONTAINER_RUNTIME_FLAG} \
  --python-choice new-venv \
  --reboot-option never \
  --kmd-version "${KMD_VER}" \
  --smi-version "${SMI_VER}" \
  --flash-version "${FLASH_VER}" \
  --fw-version "${FW_VER}" \
  "${METALIUM_TAG_FLAG[@]}"

INSTALLER_VENV="${HOME}/.tenstorrent-venv"
if [[ -x "${INSTALLER_VENV}/bin/python" ]]; then
  echo "${INSTALLER_VENV}" > /tmp/tenstorrent-installer-venv.path
  echo "Installer Python venv recorded at ${INSTALLER_VENV}"
else
  echo "WARNING: expected installer venv not found at ${INSTALLER_VENV}/bin/python" >&2
fi

if [[ "${HW}" -eq 1 ]]; then
  TT_METALIUM_WRAPPER="${HOME}/.local/bin/tt-metalium"
  if [[ -x "${TT_METALIUM_WRAPPER}" ]]; then
    grep -E '^METALIUM_IMAGE=' "${TT_METALIUM_WRAPPER}" | head -n1 | cut -d= -f2- | tr -d '"' \
      > /tmp/tenstorrent-metalium-image.path || true
    echo "Installer tt-metalium image: $(cat /tmp/tenstorrent-metalium-image.path 2>/dev/null || echo unknown)"
  fi

  if [[ -n "${METAL_UPSTREAM_TAG}" ]]; then
    METAL_UPSTREAM_IMAGE="$(metal_upstream_image_ref "${METAL_UPSTREAM_TAG}")"
    echo "Pulling upstream-tests-bh (golden metal upstream step; not part of tt-installer)..."
    if ${CONTAINER_RUNTIME} pull "${METAL_UPSTREAM_IMAGE}"; then
      echo "${METAL_UPSTREAM_IMAGE}" > /tmp/tenstorrent-metal-upstream-image.path
    else
      echo "WARNING: failed to pull ${METAL_UPSTREAM_IMAGE}; upstream step will retry pull" >&2
      echo "${METAL_UPSTREAM_IMAGE}" > /tmp/tenstorrent-metal-upstream-image.path
    fi
  else
    echo "Skipping upstream-tests-bh pull (metal-upstream-tag not set in golden.json)."
    rm -f /tmp/tenstorrent-metal-upstream-image.path
  fi
fi

echo "=== Install finished ==="
