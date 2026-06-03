#!/usr/bin/env bash
# Metal unit test: tt-metalium release container smoke (tt-installer metalium-workload pattern).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
GOLDEN_JSON="${GOLDEN_JSON:-${REPO_ROOT}/golden.json}"
GOLDEN_METAL_BOARDS_JSON="${BOARDS_JSON:-${REPO_ROOT}/.github/golden-metal-boards.json}"
WORKLOAD_PY="${REPO_ROOT}/tests/metalium-workload.py"

# shellcheck source=golden-metal-images.sh
source "${SCRIPT_DIR}/golden-metal-images.sh"
# shellcheck source=golden-metal-board.sh
source "${SCRIPT_DIR}/golden-metal-board.sh"
# shellcheck source=golden-echo-test-versions.sh
source "${SCRIPT_DIR}/golden-echo-test-versions.sh"

if [[ ! -f "${GOLDEN_JSON}" ]]; then
  echo "golden.json not found at ${GOLDEN_JSON}" >&2
  exit 1
fi
if [[ ! -f "${WORKLOAD_PY}" ]]; then
  echo "workload script not found at ${WORKLOAD_PY}" >&2
  exit 1
fi

golden_metal_require_board

if [[ "$(golden_metal_board_bool metal-unit-test true)" != "true" ]]; then
  echo "SKIP: metal unit test disabled for this runner"
  exit 0
fi

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
  resolve_metalium_release_image "${GOLDEN_JSON}"
}

_resolve_container_cmd
METAL_VERSION="$(read_golden_metal_version "${GOLDEN_JSON}")"
METALIUM_IMAGE="$(_resolve_metalium_image)"

golden_echo_test_banner "Metal unit test (tt-metalium release container)"
golden_echo_golden_json_pins "${GOLDEN_JSON}"
echo "running:"
echo "  metal-version: ${METAL_VERSION}"
echo "  image:         ${METALIUM_IMAGE}"
echo "  runner label:  ${golden_metal_match_key}"
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

echo "PASS: metal unit test"
