#!/usr/bin/env bash
# TTNN unit test: tt-metalium release container smoke (tt-installer metalium-workload pattern).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
GOLDEN_JSON="${GOLDEN_JSON:-${REPO_ROOT}/golden.json}"
WORKLOAD_PY="${REPO_ROOT}/tests/metalium-workload.py"
RUNNER_LABEL="${GOLDEN_RUNNER_LABEL:-${GITHUB_RUNNER_NAME:-}}"

readonly GOLDEN_METALIUM_RELEASE_REPO="ghcr.io/tenstorrent/tt-metal/tt-metalium-ubuntu-22.04-release-amd64"

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

resolve_metalium_release_image() {
  printf '%s:%s\n' "${GOLDEN_METALIUM_RELEASE_REPO}" "$(normalize_metal_image_tag "$(read_golden_metal_version)")"
}

golden_check_hugepages() {
  if [[ -d /dev/hugepages-1G ]] || [[ -d /dev/hugepages ]]; then
    return 0
  fi
  echo "FAIL: host hugepages are not configured (/dev/hugepages-1G and /dev/hugepages missing)." >&2
  echo "  Run golden-install.sh --hw (uses --install-hugepages)." >&2
  return 1
}

if [[ ! -f "${GOLDEN_JSON}" ]]; then
  echo "golden.json not found at ${GOLDEN_JSON}" >&2
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required" >&2
  exit 1
fi
if [[ ! -f "${WORKLOAD_PY}" ]]; then
  echo "workload script not found at ${WORKLOAD_PY}" >&2
  exit 1
fi

golden_check_hugepages

_resolve_container_cmd() {
  if [[ -n "${CONTAINER_CMD:-}" ]]; then
    return 0
  fi
  if command -v docker >/dev/null 2>&1; then
    CONTAINER_CMD=docker
  elif command -v podman >/dev/null 2>&1; then
    CONTAINER_CMD=podman
  else
    echo "docker or podman is required" >&2
    exit 1
  fi
}

_resolve_metalium_image() {
  if [[ -f /tmp/tenstorrent-metalium-image.path ]]; then
    cat /tmp/tenstorrent-metalium-image.path
    return 0
  fi
  resolve_metalium_release_image
}

_resolve_container_cmd
METAL_VERSION="$(read_golden_metal_version)"
METALIUM_IMAGE="$(_resolve_metalium_image)"

printf '\n========== TTNN unit test (tt-metalium release container) ==========\n'
echo "golden.json pins:"
jq -r '
  "  installer:     \(.installer)",
  "  kmd:           \(.kmd)",
  "  smi:           \(.smi)",
  "  flash:         \(.flash)",
  "  firmware:      \(.firmware)",
  "  metal-version: \(.["metal-version"] // .["metalium-image-tag"] // "n/a")"
' "${GOLDEN_JSON}"
echo "running:"
echo "  metal-version: ${METAL_VERSION}"
echo "  image:         ${METALIUM_IMAGE}"
echo "  runner label:  ${RUNNER_LABEL:-n/a}"
echo "  instance:      ${GITHUB_RUNNER_NAME:-n/a}"
echo "  runtime:       ${CONTAINER_CMD}"
echo "  workload:      ${WORKLOAD_PY}"

if ! ${CONTAINER_CMD} pull "${METALIUM_IMAGE}"; then
  echo "FAIL: could not pull ${METALIUM_IMAGE}" >&2
  exit 1
fi

${CONTAINER_CMD} run --rm \
  --privileged \
  --log-driver none \
  --volume=/dev/hugepages-1G:/dev/hugepages-1G \
  --volume="${WORKLOAD_PY}:/metalium-workload.py:ro" \
  --device=/dev/tenstorrent:/dev/tenstorrent \
  --network=host \
  --security-opt label=disable \
  --entrypoint python3 \
  "${METALIUM_IMAGE}" \
  /metalium-workload.py

echo "PASS: ttnn unit test"
