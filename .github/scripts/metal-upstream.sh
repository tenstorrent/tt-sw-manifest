#!/usr/bin/env bash
# Metal upstream tests: upstream-tests-bh image (host KMD/firmware — no re-flash in this step).
# Not currently run in CI. When re-enabled, set METAL_TARGET (default: blackhole_no_models).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
GOLDEN_JSON="${GOLDEN_JSON:-${REPO_ROOT}/golden.json}"
RUNNER_LABEL="${GOLDEN_RUNNER_LABEL:-${GITHUB_RUNNER_NAME:-}}"

UPSTREAM_SCRIPT="dockerfile/upstream_test_images/run_upstream_tests_vanilla.sh"
CONTAINER_WORKDIR="/home/user/tt-metal"
METAL_TARGET="${METAL_TARGET:-blackhole_no_models}"
PATCHES="${METAL_UPSTREAM_PATCHES:-}"

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

metal_upstream_image_ref() {
  printf '%s:%s\n' "${GOLDEN_METAL_UPSTREAM_REPO}" "$(normalize_metal_image_tag "$1")"
}

resolve_metal_upstream_image() {
  local tag
  tag="$(read_golden_metal_upstream_tag)"
  if [[ -z "${tag}" ]]; then
    echo "metal-upstream-tag is not set in golden.json" >&2
    return 1
  fi
  metal_upstream_image_ref "${tag}"
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

if [[ -z "$(read_golden_metal_upstream_tag)" ]]; then
  echo "SKIP: metal-upstream-tag is not set in golden.json."
  exit 0
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

_resolve_upstream_image() {
  if [[ -f /tmp/tenstorrent-metal-upstream-image.path ]]; then
    cat /tmp/tenstorrent-metal-upstream-image.path
    return 0
  fi
  resolve_metal_upstream_image
}

_resolve_container_cmd
METAL_VERSION="$(read_golden_metal_version)"
METAL_UPSTREAM_TAG="$(read_golden_metal_upstream_tag)"
METAL_IMAGE="$(_resolve_upstream_image)"

printf '\n========== Metal upstream tests (upstream-tests-bh) ==========\n'
echo "golden.json pins:"
jq -r '
  "  installer:     \(.installer)",
  "  kmd:           \(.kmd)",
  "  smi:           \(.smi)",
  "  flash:         \(.flash)",
  "  firmware:      \(.firmware)",
  "  metal-version: \(.["metal-version"] // .["metalium-image-tag"] // "n/a")",
  "  metal-upstream-tag: \(.["metal-upstream-tag"] // "(not set)")"
' "${GOLDEN_JSON}"
echo "running:"
echo "  metal-version:      ${METAL_VERSION}"
echo "  metal-upstream-tag: ${METAL_UPSTREAM_TAG}"
echo "  image:              ${METAL_IMAGE}"
echo "  target:             ${METAL_TARGET}"
echo "  runner label:       ${RUNNER_LABEL:-n/a}"
echo "  instance:           ${GITHUB_RUNNER_NAME:-n/a}"
echo "  runtime:            ${CONTAINER_CMD}"
echo "  script:             ${UPSTREAM_SCRIPT}"

if ! ${CONTAINER_CMD} pull "${METAL_IMAGE}"; then
  echo "FAIL: could not pull ${METAL_IMAGE}" >&2
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
    --entrypoint bash \
    "${METAL_IMAGE}" \
    -lc "$1"
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
