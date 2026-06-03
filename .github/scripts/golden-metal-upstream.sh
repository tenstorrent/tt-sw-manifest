#!/usr/bin/env bash
# Metal upstream tests: tt-system-firmware metal.yml style (upstream-tests-bh image).
# Uses installer KMD/firmware on host — no re-flash or KMD swap in this step.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
GOLDEN_JSON="${GOLDEN_JSON:-${REPO_ROOT}/golden.json}"
GOLDEN_METAL_BOARDS_JSON="${BOARDS_JSON:-${REPO_ROOT}/.github/golden-metal-boards.json}"

UPSTREAM_SCRIPT="dockerfile/upstream_test_images/run_upstream_tests_vanilla.sh"
CONTAINER_WORKDIR="/home/user/tt-metal"

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

golden_metal_require_board

if [[ "$(golden_metal_board_bool metal-upstream false)" != "true" ]]; then
  echo "SKIP: $(jq -r '.["upstream-skip-reason"] // "metal upstream not configured for this runner"' <<<"${GOLDEN_METAL_BOARD}")"
  exit 0
fi

if ! golden_metal_upstream_enabled "${GOLDEN_JSON}"; then
  echo "SKIP: metal-upstream-tag is not set in golden.json."
  echo "  upstream-tests-bh is published as CI dev tags (e.g. v0.71.0-dev20260516-2-g…), not release tags."
  echo "  metal-version ($(read_golden_metal_version "${GOLDEN_JSON}")) applies to tt-metalium release only."
  echo "  To run upstream on p150b, pin an existing tag: ghcr.io/tenstorrent/tt-metal/upstream-tests-bh:<tag>"
  exit 0
fi

METAL_TARGET="$(jq -r '.["metal-target"] // empty' <<<"${GOLDEN_METAL_BOARD}")"
if [[ -z "${METAL_TARGET}" || "${METAL_TARGET}" == "null" ]]; then
  echo "metal-target is required when metal-upstream is enabled" >&2
  exit 1
fi
PATCHES="$(jq -r '.["upstream-patches"] // [] | join(",")' <<<"${GOLDEN_METAL_BOARD}")"

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

_resolve_upstream_image() {
  if [[ -f /tmp/tenstorrent-metal-upstream-image.path ]]; then
    cat /tmp/tenstorrent-metal-upstream-image.path
    return 0
  fi
  resolve_metal_upstream_image "${GOLDEN_JSON}"
}

_resolve_container_cmd
METAL_VERSION="$(read_golden_metal_version "${GOLDEN_JSON}")"
METAL_UPSTREAM_TAG="$(read_golden_metal_upstream_tag "${GOLDEN_JSON}")"
METAL_IMAGE="$(_resolve_upstream_image)"

golden_echo_test_banner "Metal upstream tests (upstream-tests-bh)"
golden_echo_golden_json_pins "${GOLDEN_JSON}"
echo "running:"
echo "  metal-version:       ${METAL_VERSION} (release / unit test)"
echo "  metal-upstream-tag:  ${METAL_UPSTREAM_TAG}"
echo "  image:               ${METAL_IMAGE}"
echo "  target:        ${METAL_TARGET}"
echo "  runner label:  ${golden_metal_match_key}"
echo "  instance:      ${GITHUB_RUNNER_NAME:-n/a}"
echo "  runtime:       ${CONTAINER_CMD}"
echo "  script:        ${UPSTREAM_SCRIPT}"

if ! ${CONTAINER_CMD} pull "${METAL_IMAGE}"; then
  echo "FAIL: could not pull ${METAL_IMAGE}" >&2
  echo "Check metal-upstream-tag in golden.json — tag must exist on GHCR (dev tags, not release semver)." >&2
  exit 1
fi

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
'${UPSTREAM_SCRIPT}' '${METAL_TARGET}'
"

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
echo "PASS: metal upstream (${METAL_TARGET})"
