#!/usr/bin/env bash
# tt-metalium container smoke test after golden installer (tt-installer test-hosted-n150 pattern).
# Uses the image the installer pulled — not upstream-tests-bh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
GOLDEN_JSON="${GOLDEN_JSON:-${REPO_ROOT}/golden.json}"
BOARDS_JSON="${BOARDS_JSON:-${REPO_ROOT}/.github/golden-metal-boards.json}"
WORKLOAD_PY="${REPO_ROOT}/tests/metalium-workload.py"
# Workflow matrix label (e.g. tt-ubuntu-2204-n150-stable). Do not use GITHUB_RUNNER_NAME — that
# includes the ephemeral suffix (…-runner-9swlw) and will not match board config.
GOLDEN_RUNNER_LABEL="${GOLDEN_RUNNER_LABEL:-}"
GITHUB_RUNNER_NAME="${GITHUB_RUNNER_NAME:-}"

# shellcheck source=golden-metalium-tag.sh
source "${SCRIPT_DIR}/golden-metalium-tag.sh"

if [[ ! -f "${GOLDEN_JSON}" ]]; then
  echo "golden.json not found at ${GOLDEN_JSON}" >&2
  exit 1
fi
if [[ ! -f "${BOARDS_JSON}" ]]; then
  echo "board config not found at ${BOARDS_JSON}" >&2
  exit 1
fi
if [[ ! -f "${WORKLOAD_PY}" ]]; then
  echo "workload script not found at ${WORKLOAD_PY}" >&2
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required" >&2
  exit 1
fi

_match_runner_label() {
  local key="$1"
  jq -c --arg key "${key}" '
    [.[]
      | (.["runner-label"] // .runner // "") as $prefix
      | select($prefix != "" and ($key == $prefix or ($key | startswith($prefix))))
    ][0]
  ' "${BOARDS_JSON}"
}

_resolve_metalium_image() {
  if [[ -f /tmp/tenstorrent-metalium-image.path ]]; then
    cat /tmp/tenstorrent-metalium-image.path
    return 0
  fi
  local tag
  tag="$(normalize_metalium_image_tag "$(jq -r '.["metalium-image-tag"]' "${GOLDEN_JSON}")")"
  printf 'ghcr.io/tenstorrent/tt-metal/tt-metalium-ubuntu-22.04-release-amd64:%s\n' "${tag}"
}

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

MATCH_KEY="${GOLDEN_RUNNER_LABEL}"
if [[ -z "${MATCH_KEY}" ]]; then
  echo "WARNING: GOLDEN_RUNNER_LABEL unset; falling back to GITHUB_RUNNER_NAME (${GITHUB_RUNNER_NAME})" >&2
  MATCH_KEY="${GITHUB_RUNNER_NAME}"
fi

BOARD="$(_match_runner_label "${MATCH_KEY}")"
if [[ -z "${BOARD}" || "${BOARD}" == "null" ]]; then
  echo "No metal board profile for runner label '${MATCH_KEY}' in ${BOARDS_JSON}" >&2
  echo "Set GOLDEN_RUNNER_LABEL to the workflow matrix value (e.g. tt-ubuntu-2204-n150-stable)." >&2
  exit 1
fi

TEST_KIND="$(jq -r '.test // "metalium-workload"' <<<"${BOARD}")"
if [[ "${TEST_KIND}" == "skip" ]]; then
  echo "SKIP: $(jq -r '.["skip-reason"] // "metal test skipped for this runner"' <<<"${BOARD}")"
  exit 0
fi
if [[ "${TEST_KIND}" != "metalium-workload" ]]; then
  echo "Unsupported test kind '${TEST_KIND}' in ${BOARDS_JSON}" >&2
  exit 1
fi

_resolve_container_cmd
METALIUM_IMAGE="$(_resolve_metalium_image)"

echo "=== tt-metalium workload (golden integration) ==="
echo "Runner label:  ${MATCH_KEY}"
echo "Instance name: ${GITHUB_RUNNER_NAME:-n/a}"
echo "Image:         ${METALIUM_IMAGE}"
echo "Runtime:       ${CONTAINER_CMD}"

# Installer may have cached the image; pull surfaces actionable errors if missing.
if ! ${CONTAINER_CMD} pull "${METALIUM_IMAGE}"; then
  echo "FAIL: could not pull ${METALIUM_IMAGE}" >&2
  echo "Use a published GHCR tag (e.g. v0.71.2, not bare 0.71.2)." >&2
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

echo "PASS: tt-metalium container workload"
