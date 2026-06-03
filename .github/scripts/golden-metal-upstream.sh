#!/usr/bin/env bash
# Run tt-metal upstream integration tests in the image pinned by golden.json / tt-installer.
# Adapted from tenstorrent/tt-system-firmware/.github/workflows/metal.yml — without rebuilding
# firmware, re-flashing, or swapping KMD (customer already ran tt-installer on this host).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
GOLDEN_JSON="${GOLDEN_JSON:-${REPO_ROOT}/golden.json}"
BOARDS_JSON="${BOARDS_JSON:-${REPO_ROOT}/.github/golden-metal-boards.json}"
RUNNER_NAME="${RUNNER_NAME:-${GITHUB_RUNNER_NAME:-}}"

UPSTREAM_SCRIPT="dockerfile/upstream_test_images/run_upstream_tests_vanilla.sh"
CONTAINER_WORKDIR="/home/user/tt-metal"

if [[ ! -f "${GOLDEN_JSON}" ]]; then
  echo "golden.json not found at ${GOLDEN_JSON}" >&2
  exit 1
fi
if [[ ! -f "${BOARDS_JSON}" ]]; then
  echo "board config not found at ${BOARDS_JSON}" >&2
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required" >&2
  exit 1
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
    echo "docker or podman is required to run metal upstream tests" >&2
    exit 1
  fi
}

_resolve_metal_image() {
  if [[ -f /tmp/tenstorrent-metal-upstream-image.path ]]; then
    cat /tmp/tenstorrent-metal-upstream-image.path
    return 0
  fi
  local from_golden
  from_golden="$(jq -r '.["metal-upstream-image"] // empty' "${GOLDEN_JSON}")"
  if [[ -n "${from_golden}" && "${from_golden}" != "null" ]]; then
    printf '%s\n' "${from_golden}"
    return 0
  fi
  local tag
  tag="$(jq -r '.["metalium-image-tag"]' "${GOLDEN_JSON}")"
  printf 'ghcr.io/tenstorrent/tt-metal/upstream-tests-bh:%s\n' "${tag}"
}

_resolve_container_cmd
METAL_IMAGE="$(_resolve_metal_image)"

if [[ -z "${RUNNER_NAME}" ]]; then
  echo "RUNNER_NAME or GITHUB_RUNNER_NAME must be set to select a board profile" >&2
  exit 1
fi

BOARD="$(jq -c --arg runner "${RUNNER_NAME}" '[.[] | select(.runner == $runner)][0]' "${BOARDS_JSON}")"
if [[ -z "${BOARD}" || "${BOARD}" == "null" ]]; then
  echo "No metal board profile for runner '${RUNNER_NAME}' in ${BOARDS_JSON}" >&2
  exit 1
fi

if [[ "$(jq -r '.skip // false' <<<"${BOARD}")" == "true" ]]; then
  echo "SKIP: $(jq -r '.["skip-reason"] // "metal upstream not configured for this runner"' <<<"${BOARD}")"
  exit 0
fi

METAL_TARGET="$(jq -r '.["metal-target"]' <<<"${BOARD}")"
PATCHES="$(jq -r '.patches // [] | join(",")' <<<"${BOARD}")"

echo "=== Metal upstream (golden integration) ==="
echo "Runner:      ${RUNNER_NAME}"
echo "Image:       ${METAL_IMAGE}"
echo "Target:      ${METAL_TARGET}"
echo "Runtime:     ${CONTAINER_CMD}"
echo "Note:        using installer stack on host (no fw re-flash / no KMD swap in this step)"

LOG_FILE="$(mktemp)"
cleanup() {
  rm -f "${LOG_FILE}"
}

run_in_container() {
  # shellcheck disable=SC2086
  "${CONTAINER_CMD}" run --rm \
    --cap-add SYS_MODULE \
    --device /dev/tenstorrent \
    --user=root \
    --volume=/dev/hugepages-1G:/dev/hugepages-1G \
    --volume=/dev/hugepages:/dev/hugepages \
    --env=ARCH_NAME=blackhole \
    --env=HOME="${CONTAINER_WORKDIR}" \
    --workdir="${CONTAINER_WORKDIR}" \
    --network=host \
    "${METAL_IMAGE}" \
    bash -lc "$1"
}

CONTAINER_SCRIPT="set -euo pipefail
cd '${CONTAINER_WORKDIR}'
if [[ ! -f '${UPSTREAM_SCRIPT}' ]]; then
  echo 'FAIL: ${UPSTREAM_SCRIPT} not found in image' >&2
  exit 1
fi
if [[ '${PATCHES}' == *determinism* ]]; then
  sed -i 's/--determinism-check-interval 1/--determinism-check-interval 0/g' '${UPSTREAM_SCRIPT}'
fi
if [[ '${PATCHES}' == *whisper_ci* ]]; then
  sed -i 's/pytest\\(.*\\)test_demo_for_conditional_generation/CI=false pytest\\1test_demo_for_conditional_generation/g' '${UPSTREAM_SCRIPT}'
fi
'${UPSTREAM_SCRIPT}' '${METAL_TARGET}'"

echo "while true; do curl -fsSL -o /dev/null https://tenstorrent.com || true; sleep 10; done" > /tmp/golden-metal-network-keepalive
chmod +x /tmp/golden-metal-network-keepalive
/tmp/golden-metal-network-keepalive &
KEEPALIVE_PID=$!

trap 'cleanup; kill "${KEEPALIVE_PID}" 2>/dev/null || true; rm -f /tmp/golden-metal-network-keepalive' EXIT

if ! run_in_container "${CONTAINER_SCRIPT}" >"${LOG_FILE}" 2>&1; then
  echo "FAIL: metal upstream tests failed" >&2
  tail -n 200 "${LOG_FILE}" >&2 || true
  exit 1
fi

tail -n 50 "${LOG_FILE}"
echo "PASS: metal upstream (${METAL_TARGET}) completed in ${METAL_IMAGE}"
