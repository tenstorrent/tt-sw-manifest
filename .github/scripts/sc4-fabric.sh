#!/usr/bin/env bash
# SC4 fabric: tt-metal's run_fabric_tests.sh on each quad as one 32x4 2D torus
# (--config 4x32, one Galaxy per host), the same two runs as tt-metal's
# "SC4 physical discovery, health, stability, and DC validation" job:
#   stability    test_fabric_2d_torus_stability.yaml, the *_short groups
#   neighbor     test_fabric_sanity_neighbor_exchange.yaml, 2DTorusXYNeighborExchange
#                (tt-metal calls this the DC validation)
#
# run_fabric_tests.sh does not reorder hosts for 4x32, so the quad is put in
# physical ring order first with tt-metal's resolve_host_ring_order.py and the
# quad's FSD. A run passes when the test exits 0 and reports executed tests; on
# failure, analyze_fabric_results.py names the cause.
#
# Env: see sc4-common.sh, plus
#   FABRIC_TIMEOUT_MIN  timeout per run (default 20)
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/sc4-common.sh"

FABRIC_TIMEOUT_MIN="${FABRIC_TIMEOUT_MIN:-20}"
TEST_YAMLS=tests/tt_metal/tt_fabric/test_infra/test_yamls

pick_mpi_if || exit 1
stage_exabox || { echo "ERROR: could not copy the exabox scripts out of ${EXABOX_IMAGE}" >&2; exit 1; }
cd "${EXABOX_ROOT}" || exit 1

run_fabric() { # run_fabric <quad> <hosts> <fsd> <name> [run_fabric_tests args...]
  local q="$1" hosts="$2" fsd="$3" name="$4"; shift 4
  local tag="quad-${q}-${name}" start=${SECONDS} ec took log
  echo; echo "=== Fabric ${name}, quad ${q} (${hosts}) ==="
  timeout --kill-after=60 "${FABRIC_TIMEOUT_MIN}m" ./tools/scaleout/exabox/run_fabric_tests.sh \
    --hosts "${hosts}" --image "${EXABOX_IMAGE}" --config 4x32 --fsd "${fsd}" \
    --mpi-if "${MPI_IF}" --output "${SC4_SCRATCH}/fabric-${tag}" "$@" 2>&1 | tee "${SC4_LOG_DIR}/${tag}.log"
  ec=${PIPESTATUS[0]}
  cp -r "${SC4_SCRATCH}/fabric-${tag}" "${SC4_LOG_DIR}/${tag}" 2>/dev/null || true
  took="$(( (SECONDS - start) / 60 ))m$(( (SECONDS - start) % 60 ))s"
  log="${SC4_LOG_DIR}/${tag}.log"
  if [[ ${ec} -eq 124 || ${ec} -eq 137 ]]; then
    record FAIL "fabric ${name} quad ${q}" "timed out after ${FABRIC_TIMEOUT_MIN}m (see ${tag}.log)"
  elif [[ ${ec} -ne 0 ]]; then
    local why
    why=$(python3 tools/scaleout/exabox/analyze_fabric_results.py "${log}" 2>&1 | sed 's/\x1b\[[0-9;]*m//g' |
      tee "${SC4_LOG_DIR}/${tag}-analysis.txt" | grep -m1 -iE 'fail|error|hang|timeout' || true)
    record FAIL "fabric ${name} quad ${q}" "exit ${ec} in ${took}: ${why:-see ${tag}.log}"
  elif ! grep -qE 'Tests: [1-9][0-9]* executed' "${log}"; then
    record FAIL "fabric ${name} quad ${q}" "exit 0 but no tests ran (check --test-config / --filter)"
  else
    record PASS "fabric ${name} quad ${q}" "$(grep -oE 'Tests: [0-9]+ executed, [0-9]+ failed' "${log}" | tail -1) in ${took}"
  fi
}

for q in "${QUAD_NAMES[@]}"; do
  if ! fsd=$(stage_quad_fsd "${q}"); then
    record FAIL "fabric quad ${q}" "could not stage the quad FSD from $(quad_fsd_source "${q}")"
    continue
  fi
  ring=$(python3 tools/scaleout/exabox/resolve_host_ring_order.py --hosts "${QUAD_HOSTS[$q]}" --fsd "${fsd}" |
    python3 -c 'import json,sys; r=json.load(sys.stdin); print(r.get("ordered_hosts") or "ERROR: " + r.get("message", "?"))')
  if [[ -z "${ring}" || "${ring}" == ERROR* ]]; then
    record FAIL "fabric quad ${q}" "hosts do not form a ring in the FSD: ${ring}"
    continue
  fi
  echo "Quad ${q} ring order: ${ring}"

  run_fabric "${q}" "${ring}" "${fsd}" stability --filter 'name.*_short'
  run_fabric "${q}" "${ring}" "${fsd}" neighbor \
    --test-config "${TEST_YAMLS}/test_fabric_sanity_neighbor_exchange.yaml" \
    --filter name.2DTorusXYNeighborExchange
done

summarize "SC4 fabric (run_fabric_tests.sh --config 4x32 per quad)"
