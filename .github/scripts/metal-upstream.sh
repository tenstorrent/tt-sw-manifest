#!/usr/bin/env bash
# Metal upstream tests — mirrors tt-system-firmware metal.yml:
# host KMD/firmware (no re-flash), upstream-tests-bh* image, hf-models mount,
# board-specific METAL_TARGET / HF_MODEL, and the same script patches.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
GOLDEN_JSON="${GOLDEN_JSON:-${REPO_ROOT}/golden.json}"
RUNNER_LABEL="${GOLDEN_RUNNER_LABEL:-${GITHUB_RUNNER_NAME:-}}"

UPSTREAM_SCRIPT="dockerfile/upstream_test_images/run_upstream_tests_vanilla.sh"
CONTAINER_WORKDIR="/home/user/tt-metal"
# Same host tree mounted by tt-system-firmware metal.yml.
HF_MODELS_HOST="${HF_MODELS_HOST:-/opt/tenstorrent/hf-models}"
# Syseng runners provision Instruct weights (metal.yml still names Llama-3.1-8B/).
readonly HF_LLAMA_8B="${HF_MODELS_HOST}/meta-llama/Llama-3.1-8B-Instruct/"
readonly HF_LLAMA_8B_LEGACY="${HF_MODELS_HOST}/meta-llama/Llama-3.1-8B/"
readonly HF_LLAMA_70B="${HF_MODELS_HOST}/meta-llama/Llama-3.3-70B-Instruct/"

# Optional overrides (else derived from RUNNER_LABEL).
METAL_TARGET="${METAL_TARGET:-}"
PATCHES="${METAL_UPSTREAM_PATCHES:-}"
UPSTREAM_IMAGE_REPO="${METAL_UPSTREAM_IMAGE_REPO:-}"
HF_MODEL="${HF_MODEL:-}"
LLAMA_DIR="${LLAMA_DIR:-}"
TT_CACHE_PATH="${TT_CACHE_PATH:-}"

# Prefer metal.yml path if present; else Instruct (what the golden HW runners have).
resolve_llama_8b_path() {
  if [[ -d "${HF_LLAMA_8B_LEGACY}" ]]; then
    printf '%s\n' "${HF_LLAMA_8B_LEGACY}"
  else
    printf '%s\n' "${HF_LLAMA_8B}"
  fi
}

readonly UPSTREAM_REPO_BH="ghcr.io/tenstorrent/tt-metal/upstream-tests-bh"
readonly UPSTREAM_REPO_BH_P300="ghcr.io/tenstorrent/tt-metal/upstream-tests-bh-p300"
readonly UPSTREAM_REPO_BH_QB_GE="ghcr.io/tenstorrent/tt-metal/upstream-tests-bh-qb-ge"
readonly UPSTREAM_REPO_BH_GLX="ghcr.io/tenstorrent/tt-metal/upstream-tests-bh-glx"

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

# Prefer explicit metal-upstream-tag; else metal-version (v0.72.0+ has matching upstream tags).
read_golden_metal_upstream_tag() {
  local tag
  tag="$(jq -r '.["metal-upstream-tag"] // empty' "${GOLDEN_JSON}")"
  if [[ -z "${tag}" ]]; then
    tag="$(read_golden_metal_version)"
  fi
  printf '%s\n' "${tag}"
}

metal_upstream_image_ref() {
  local repo="${1:?}"
  local tag="${2:?}"
  printf '%s:%s\n' "${repo}" "$(normalize_metal_image_tag "${tag}")"
}

# Match tt-system-firmware .github/ci_boards.json + metal.yml "Set model env".
# Upstream run_upstream_tests_vanilla.sh requires HF_MODEL + TT_CACHE_PATH when
# LLAMA_DIR is unset (single-device BH Llama demos); metal.yml only exports
# HF_MODEL / LLAMA_DIR, so we default TT_CACHE_PATH to the same Llama tree.
resolve_board_profile() {
  local board="${1:?}"

  case "${board}" in
    p100a | p150a)
      # Match tt-system-firmware metal.yml: do NOT set HF_MODEL on these boards.
      # Their /opt/tenstorrent/hf-models/.../Llama-3.1-8B-Instruct trees are empty
      # stubs; pointing HF_MODEL there makes transformers hit HuggingFace (gated)
      # instead of using a real on-host cache. Use blackhole_no_models so the
      # suite does not require Llama weights (firmware's older blackhole image
      # similarly avoids weight-backed demos when env is unset).
      : "${METAL_TARGET:=blackhole_no_models}"
      : "${UPSTREAM_IMAGE_REPO:=${UPSTREAM_REPO_BH}}"
      : "${PATCHES:=determinism,whisper_ci}"
      ;;
    p300a)
      # metal.yml sets HF_MODEL for p300a; runners have a populated Instruct cache.
      : "${METAL_TARGET:=blackhole_p300}"
      : "${UPSTREAM_IMAGE_REPO:=${UPSTREAM_REPO_BH_P300}}"
      : "${PATCHES:=determinism,whisper_ci,p300_didt}"
      _llama8="$(resolve_llama_8b_path)"
      : "${HF_MODEL:=${_llama8}}"
      : "${TT_CACHE_PATH:=${_llama8}}"
      ;;
    quietbox2)
      # Match metal.yml "Set model env": Llama-3.1-8B-Instruct for HF_MODEL + LLAMA_DIR.
      : "${METAL_TARGET:=blackhole_qb_ge}"
      : "${UPSTREAM_IMAGE_REPO:=${UPSTREAM_REPO_BH_QB_GE}}"
      : "${PATCHES:=determinism,whisper_ci}"
      : "${HF_MODEL:=${HF_LLAMA_8B}}"
      : "${LLAMA_DIR:=${HF_LLAMA_8B}}"
      ;;
    loudbox)
      : "${METAL_TARGET:=blackhole_loudbox}"
      : "${UPSTREAM_IMAGE_REPO:=${UPSTREAM_REPO_BH}}"
      : "${PATCHES:=determinism,whisper_ci,loudbox_dp}"
      : "${HF_MODEL:=${HF_LLAMA_70B}}"
      : "${LLAMA_DIR:=${HF_LLAMA_70B}}"
      ;;
    bh-galaxy)
      # Match metal.yml "Set model env": Llama-3.1-8B-Instruct for HF_MODEL + LLAMA_DIR.
      : "${METAL_TARGET:=blackhole_glx}"
      : "${UPSTREAM_IMAGE_REPO:=${UPSTREAM_REPO_BH_GLX}}"
      : "${PATCHES:=determinism,whisper_ci}"
      : "${HF_MODEL:=${HF_LLAMA_8B}}"
      : "${LLAMA_DIR:=${HF_LLAMA_8B}}"
      ;;
    *)
      if [[ -z "${METAL_TARGET}" ]]; then
        echo "FAIL: unknown runner label '${board}'." >&2
        echo "  Set GOLDEN_RUNNER_LABEL to p100a|p150a|p300a|quietbox2|loudbox|bh-galaxy," >&2
        echo "  or export METAL_TARGET (and optionally METAL_UPSTREAM_IMAGE_REPO / HF_MODEL)." >&2
        return 1
      fi
      : "${UPSTREAM_IMAGE_REPO:=${UPSTREAM_REPO_BH}}"
      : "${PATCHES:=determinism,whisper_ci}"
      ;;
  esac
}

golden_check_hugepages() {
  if [[ -d /dev/hugepages-1G ]] || [[ -d /dev/hugepages ]]; then
    return 0
  fi
  echo "FAIL: host hugepages are not configured (/dev/hugepages-1G and /dev/hugepages missing)." >&2
  echo "  Run golden-install.sh --hw (uses --install-hugepages)." >&2
  return 1
}

write_container_entrypoint() {
  local out="${1:?}"
  cat >"${out}" <<EOF
#!/usr/bin/env bash
set -euo pipefail
cd '${CONTAINER_WORKDIR}'
if [[ ! -f '${UPSTREAM_SCRIPT}' ]]; then
  echo 'FAIL: ${UPSTREAM_SCRIPT} not found in image' >&2
  exit 1
fi

PATCHES='${PATCHES}'

# Patches mirror tt-system-firmware .github/workflows/metal.yml
if [[ "\${PATCHES}" == *whisper_ci* ]]; then
  # Skip whisper performance checks (runners differ from metal CI fleets).
  sed -i 's/pytest\\(.*\\)test_demo_for_conditional_generation/CI=false pytest\\1test_demo_for_conditional_generation/g' \\
    '${UPSTREAM_SCRIPT}'
fi

if [[ "\${PATCHES}" == *p300_didt* ]]; then
  # SYS-2705 workaround: warm-up ResNet conv after cold boot on P300.
  SEARCH='echo "\\[upstream-tests\\] Running BH upstream didt tests"'
  INSERT='    pytest tests/didt/test_resnet_conv.py::test_resnet_conv -k "all" --didt-workload-iterations 100 --determinism-check-interval 0'
  sed -i "/\${SEARCH}/a\${INSERT}" '${UPSTREAM_SCRIPT}'
fi

if [[ "\${PATCHES}" == *loudbox_dp* ]]; then
  # Force data_parallel=1 so 70B weights are not replicated per device (OOM).
  sed -i 's/--data_parallel "\$data_parallel_devices"/--data_parallel 1/g' '${UPSTREAM_SCRIPT}'
  sed -i 's/-k "performance and ci-32" --data_parallel 1 --timeout 1200/-k "performance and ci-32" --data_parallel 1 --timeout 3600/' \\
    '${UPSTREAM_SCRIPT}'
  # Bump Llama-3.3-70B trace_region_size to 128 MiB (134217728).
  sed -i -E '/"Llama-3\\.3-70B":/,/},/ s/(":[[:space:]]+)[0-9]+/\\1134217728/' \\
    models/tt_transformers/demo/trace_region_config.py || true
fi

if [[ "\${PATCHES}" == *determinism* ]]; then
  sed -i 's/--determinism-check-interval 1/--determinism-check-interval 0/g' '${UPSTREAM_SCRIPT}'
fi

'${UPSTREAM_SCRIPT}' '${METAL_TARGET}'
EOF
  chmod +x "${out}"
}

if [[ ! -f "${GOLDEN_JSON}" ]]; then
  echo "golden.json not found at ${GOLDEN_JSON}" >&2
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required" >&2
  exit 1
fi

METAL_UPSTREAM_TAG="$(read_golden_metal_upstream_tag)"
if [[ -z "${METAL_UPSTREAM_TAG}" ]]; then
  echo "SKIP: neither metal-upstream-tag nor metal-version is set in golden.json."
  exit 0
fi

if [[ -z "${RUNNER_LABEL}" && -z "${METAL_TARGET}" ]]; then
  echo "FAIL: GOLDEN_RUNNER_LABEL (or GITHUB_RUNNER_NAME) or METAL_TARGET is required." >&2
  exit 1
fi

# Prefer short board labels (p100a) over full runner hostnames when label is a prefix match.
BOARD="${RUNNER_LABEL}"
case "${RUNNER_LABEL}" in
  p100a* | */p100a | *-p100a*) BOARD=p100a ;;
  p150a* | */p150a | *-p150a*) BOARD=p150a ;;
  p300a* | */p300a | *-p300a*) BOARD=p300a ;;
  quietbox2* | *-quietbox2*) BOARD=quietbox2 ;;
  loudbox* | *-loudbox*) BOARD=loudbox ;;
  bh-galaxy* | *-bh-galaxy* | *galaxy*) BOARD=bh-galaxy ;;
esac

resolve_board_profile "${BOARD}"
golden_check_hugepages

if [[ ! -d "${HF_MODELS_HOST}" ]]; then
  echo "FAIL: host weights directory missing: ${HF_MODELS_HOST}" >&2
  echo "  Same mount as tt-system-firmware metal.yml: /opt/tenstorrent/hf-models/" >&2
  exit 1
fi
echo "Host hf-models tree (metal.yml weight root):"
ls -la "${HF_MODELS_HOST}" || true
ls -la "${HF_MODELS_HOST}/meta-llama" 2>/dev/null || echo "  (no ${HF_MODELS_HOST}/meta-llama yet)"
# metal.yml does not preflight these paths; warn so logs show runner state.
if [[ -n "${HF_MODEL}" && ! -d "${HF_MODEL}" ]]; then
  echo "WARNING: HF_MODEL path missing on host: ${HF_MODEL}" >&2
fi
if [[ -n "${LLAMA_DIR}" && ! -d "${LLAMA_DIR}" ]]; then
  echo "WARNING: LLAMA_DIR path missing on host: ${LLAMA_DIR}" >&2
fi
if [[ -n "${TT_CACHE_PATH}" && ! -d "${TT_CACHE_PATH}" ]]; then
  echo "WARNING: TT_CACHE_PATH missing on host: ${TT_CACHE_PATH}" >&2
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

_resolve_upstream_image() {
  local expected
  expected="$(metal_upstream_image_ref "${UPSTREAM_IMAGE_REPO}" "${METAL_UPSTREAM_TAG}")"
  if [[ -f /tmp/tenstorrent-metal-upstream-image.path ]]; then
    local cached
    cached="$(cat /tmp/tenstorrent-metal-upstream-image.path)"
    if [[ "${cached}" == "${expected}" ]]; then
      printf '%s\n' "${cached}"
      return 0
    fi
  fi
  printf '%s\n' "${expected}"
}

_resolve_container_cmd
METAL_VERSION="$(read_golden_metal_version)"
METAL_IMAGE="$(_resolve_upstream_image)"

printf '\n========== Metal upstream tests (upstream-tests-bh*) ==========\n'
echo "golden.json pins:"
jq -r '
  "  installer:     \(.installer)",
  "  kmd:           \(.kmd)",
  "  smi:           \(.smi)",
  "  flash:         \(.flash)",
  "  firmware:      \(.firmware)",
  "  metal-version: \(.["metal-version"] // .["metalium-image-tag"] // "n/a")",
  "  metal-upstream-tag: \(.["metal-upstream-tag"] // "(fallback to metal-version)")"
' "${GOLDEN_JSON}"
echo "running:"
echo "  metal-version:      ${METAL_VERSION}"
echo "  metal-upstream-tag: ${METAL_UPSTREAM_TAG}"
echo "  image:              ${METAL_IMAGE}"
echo "  target:             ${METAL_TARGET}"
echo "  board:              ${BOARD}"
echo "  runner label:       ${RUNNER_LABEL:-n/a}"
echo "  instance:           ${GITHUB_RUNNER_NAME:-n/a}"
echo "  runtime:            ${CONTAINER_CMD}"
echo "  patches:            ${PATCHES}"
echo "  hf-models:          ${HF_MODELS_HOST}"
echo "  HF_MODEL:           ${HF_MODEL:-"(unset)"}"
echo "  LLAMA_DIR:          ${LLAMA_DIR:-"(unset)"}"
echo "  TT_CACHE_PATH:      ${TT_CACHE_PATH:-"(unset)"}"
echo "  script:             ${UPSTREAM_SCRIPT}"

if ! ${CONTAINER_CMD} pull "${METAL_IMAGE}"; then
  echo "FAIL: could not pull ${METAL_IMAGE}" >&2
  exit 1
fi

LOG_FILE="${METAL_UPSTREAM_LOG:-}"
if [[ -z "${LOG_FILE}" ]]; then
  if [[ -n "${GITHUB_WORKSPACE:-}" ]]; then
    LOG_FILE="${GITHUB_WORKSPACE}/metal-upstream-${BOARD:-unknown}.log"
  else
    LOG_FILE="/tmp/metal-upstream-output.log"
  fi
fi
ENTRYPOINT_HOST="$(mktemp)"
cleanup() {
  # Keep LOG_FILE for the workflow upload-artifact step (metal.yml pattern).
  rm -f "${ENTRYPOINT_HOST}"
}

write_container_entrypoint "${ENTRYPOINT_HOST}"

run_in_container() {
  local -a env_args=(
    --env=ARCH_NAME=blackhole
    --env=HOME="${CONTAINER_WORKDIR}"
  )
  if [[ -n "${HF_MODEL}" ]]; then
    env_args+=(--env=HF_MODEL="${HF_MODEL}")
  fi
  if [[ -n "${LLAMA_DIR}" ]]; then
    env_args+=(--env=LLAMA_DIR="${LLAMA_DIR}")
  fi
  if [[ -n "${TT_CACHE_PATH}" ]]; then
    env_args+=(--env=TT_CACHE_PATH="${TT_CACHE_PATH}")
  fi

  local -a device_args=(--device /dev/tenstorrent)
  if [[ "${BOARD}" == "bh-galaxy" && -e /dev/ipmi0 ]]; then
    device_args+=(--device /dev/ipmi0)
  fi

  # Volume path matches metal.yml: /opt/tenstorrent/hf-models/:/opt/tenstorrent/hf-models/
  "${CONTAINER_CMD}" run --rm \
    --cap-add SYS_MODULE \
    "${device_args[@]}" \
    --user=root \
    --volume=/dev/hugepages-1G:/dev/hugepages-1G \
    --volume=/dev/hugepages:/dev/hugepages \
    --volume="${HF_MODELS_HOST}/:${HF_MODELS_HOST}/" \
    --volume="${ENTRYPOINT_HOST}:/tmp/golden-metal-upstream-entrypoint.sh:ro" \
    "${env_args[@]}" \
    --workdir="${CONTAINER_WORKDIR}" \
    --network=host \
    --entrypoint bash \
    "${METAL_IMAGE}" \
    /tmp/golden-metal-upstream-entrypoint.sh
}

# Match metal.yml keepalive (no -f: tenstorrent.com can 403 and that is fine).
echo "while true; do curl --no-progress-meter -o /dev/null https://tenstorrent.com || true; sleep 10; done" > /tmp/golden-metal-network-keepalive
chmod +x /tmp/golden-metal-network-keepalive
/tmp/golden-metal-network-keepalive &
KEEPALIVE_PID=$!

trap 'cleanup; kill "${KEEPALIVE_PID}" 2>/dev/null || true; rm -f /tmp/golden-metal-network-keepalive' EXIT

echo "Full upstream log: ${LOG_FILE}"
# tee like metal.yml so the step stream and the artifact both get the full output.
set +e
run_in_container 2>&1 | tee "${LOG_FILE}"
rc=${PIPESTATUS[0]}
set -e
# Workflow upload-artifact runs as the runner user, not root.
chmod a+r "${LOG_FILE}" 2>/dev/null || true

if [[ "${rc}" -ne 0 ]]; then
  echo "FAIL: metal upstream tests failed (full log: ${LOG_FILE})" >&2
  exit 1
fi

echo "PASS: metal upstream (${METAL_TARGET}) (full log: ${LOG_FILE})"
