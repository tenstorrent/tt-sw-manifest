#!/usr/bin/env bash
# Install kmd / tt-smi / tt-flash (and optionally metalium) via tt-installer at golden.json pins.
#
# Usage:
#   golden-install.sh [--hw] [--force-flash]
#   golden-install.sh --ttis <file>
#
#   --hw           Hardware runner: hugepages, metalium container, container runtime,
#                  upstream-tests-bh pull. Requires root.
#   --force-flash  Flash firmware during install (default: off).
#   --ttis <file>  No-hardware install driven by a compiled .ttis file via
#                  tt-installer --import-schema (version pins come from the file,
#                  not from individual flags). Mutually exclusive with --hw.
set -euo pipefail

GOLDEN_JSON="${GOLDEN_JSON:-/workspace/golden.json}"
INSTALLER_URL="${INSTALLER_URL:-}"
HW="${GOLDEN_HW:-0}"
FORCE_FLASH="${FORCE_FLASH:-0}"
TTIS_FILE="${TTIS_FILE:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --hw) HW=1; shift ;;
    --force-flash) FORCE_FLASH=1; shift ;;
    --ttis) TTIS_FILE="${2:?--ttis requires a file path}"; shift 2 ;;
    -h | --help)
      sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
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

record_installer_venv() {
  local venv="${HOME}/.tenstorrent-venv"
  if [[ -x "${venv}/bin/python" ]]; then
    echo "${venv}" > /tmp/tenstorrent-installer-venv.path
    echo "Installer Python venv recorded at ${venv}"
  else
    echo "WARNING: expected installer venv not found at ${venv}/bin/python" >&2
  fi
}

# ── .ttis import mode (no hardware) ──────────────────────────────────────────
# Install the stack from a compiled .ttis file. tt-installer's install.sh sources
# ttis.sh from its own directory, so we fetch both into /tmp. Version pins,
# hugepages/sfpi, firmware (off) and container runtime all come from the file;
# only the non-schema components are disabled here.
if [[ -n "${TTIS_FILE}" ]]; then
  if [[ "${HW}" -eq 1 ]]; then
    echo "--ttis is a no-hardware path; do not combine with --hw" >&2
    exit 2
  fi
  if [[ ! -f "${TTIS_FILE}" ]]; then
    echo "ttis file not found at ${TTIS_FILE}" >&2
    exit 1
  fi
  TTIS_URL="${TTIS_URL:-https://github.com/tenstorrent/tt-installer/releases/download/v${INSTALLER_VER}/ttis.sh}"

  echo "=== Golden install (import .ttis, no hardware) ==="
  echo "golden.json: ${GOLDEN_JSON}"
  echo "ttis file:   ${TTIS_FILE}"
  echo "installer:   v${INSTALLER_VER} (${INSTALLER_URL})"

  curl -fsSL "${INSTALLER_URL}" -o /tmp/tt-install.sh
  curl -fsSL "${TTIS_URL}" -o /tmp/ttis.sh
  chmod +x /tmp/tt-install.sh

  timeout 900 bash /tmp/tt-install.sh \
    --mode-non-interactive \
    --import-schema "${TTIS_FILE}" \
    --no-install-metalium-container \
    --no-install-metalium-models-container \
    --no-install-forge-container \
    --no-install-inference-server \
    --no-install-studio \
    --reboot-option never

  record_installer_venv
  echo "=== Install finished (import) ==="
  exit 0
fi

if [[ "${FORCE_FLASH}" -eq 1 ]]; then
  FW_UPDATE_ARGS=(--update-firmware force)
  FW_NOTE="flash enabled (--force-flash)"
else
  FW_UPDATE_ARGS=(--update-firmware off)
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
  HUGE_PAGES_ARGS=(--install-hugepages)
  METALIUM_ARGS=(--install-metalium-container)
  CONTAINER_RUNTIME_ARGS=(--install-container-runtime "${CONTAINER_RUNTIME}")
  METALIUM_TAG_ARGS=(--metalium-image-tag "${METAL_VERSION}")
else
  echo "=== Golden install (no hardware) ==="
  echo "golden.json: ${GOLDEN_JSON}"
  echo "installer:   v${INSTALLER_VER} (${INSTALLER_URL})"
  echo "kmd:         ${KMD_VER}"
  echo "smi:         ${SMI_VER}"
  echo "flash:       ${FLASH_VER}"
  echo "firmware:    ${FW_VER} (${FW_NOTE})"

  INSTALL_TIMEOUT=900
  HUGE_PAGES_ARGS=(--no-install-hugepages)
  METALIUM_ARGS=(--no-install-metalium-container)
  CONTAINER_RUNTIME_ARGS=(--install-container-runtime no)
  METALIUM_TAG_ARGS=()
fi

curl -fsSL "${INSTALLER_URL}" -o /tmp/tt-install.sh
chmod +x /tmp/tt-install.sh

timeout "${INSTALL_TIMEOUT}" bash /tmp/tt-install.sh \
  --mode-non-interactive \
  --install-kmd \
  "${HUGE_PAGES_ARGS[@]}" \
  "${FW_UPDATE_ARGS[@]}" \
  "${METALIUM_ARGS[@]}" \
  --no-install-metalium-models-container \
  --no-install-forge-container \
  --no-install-sfpi \
  --no-install-inference-server \
  --no-install-studio \
  "${CONTAINER_RUNTIME_ARGS[@]}" \
  --python-choice new-venv \
  --reboot-option never \
  --kmd-version "${KMD_VER}" \
  --smi-version "${SMI_VER}" \
  --flash-version "${FLASH_VER}" \
  --fw-version "${FW_VER}" \
  "${METALIUM_TAG_ARGS[@]}"

record_installer_venv

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
