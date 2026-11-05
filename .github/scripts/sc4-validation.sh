#!/usr/bin/env bash
# SC4 validation: tt-metal's run_validation.sh on each quad, one quad at a time.
#
# Each iteration brings the cross-host Ethernet ports down, runs
# tt-smi -glx_reset on every host, discovers the topology, compares it with the
# quad's FSD and sends traffic over every link. The FSD is the committed
# .github/sc4/fsd-quad-<name>.textproto when there is one (the provisioner's
# exabox FSD does not have the current 4+4 cabling; see fsd-from-discovery.py),
# else the exabox FSD cut down to the quad's four hosts (fsd-subset.py).
#
# run_validation.sh exits 0 even when an iteration fails, so the verdict comes
# from tt-metal's analyze_validation_results.py: exit 0 means at least 80% of the
# iterations were healthy; any other code names the failure (missing or extra
# connections, unhealthy links, DRAM training, timeouts, ...).
#
# Quads run one after the other: the port-down and resets of one quad flap the
# links that cable it to the other.
#
# Env: see sc4-common.sh, plus
#   VALIDATION_ITERATIONS  iterations per quad (default 3)
#   VALIDATION_TIMEOUT_MIN timeout per quad (default 30)
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/sc4-common.sh"

VALIDATION_ITERATIONS="${VALIDATION_ITERATIONS:-3}"
VALIDATION_TIMEOUT_MIN="${VALIDATION_TIMEOUT_MIN:-30}"

pick_mpi_if || exit 1
stage_exabox || { echo "ERROR: could not copy the exabox scripts out of ${EXABOX_IMAGE}" >&2; exit 1; }
cd "${EXABOX_ROOT}" || exit 1

for q in "${QUAD_NAMES[@]}"; do
  hosts="${QUAD_HOSTS[$q]}"
  # The output directory is bind-mounted into the containers on every host, so
  # keep it in the scratch directory, not the runner workspace: Docker creates a
  # missing mount source as root, which a later checkout cannot delete.
  out="${SC4_SCRATCH}/validation-quad-${q}"
  echo; echo "=== Validation, quad ${q} (${hosts}), ${VALIDATION_ITERATIONS} iterations ==="
  if ! fsd=$(stage_quad_fsd "${q}"); then
    record FAIL "validation quad ${q}" "could not stage the quad FSD from $(quad_fsd_source "${q}")"
    continue
  fi
  start=${SECONDS}
  timeout --kill-after=60 "${VALIDATION_TIMEOUT_MIN}m" ./tools/scaleout/exabox/run_validation.sh \
    --hosts "${hosts}" --image "${EXABOX_IMAGE}" --mpi-if "${MPI_IF}" \
    --factory-descriptor-path "${fsd}" --volume "${SC4_SCRATCH}" \
    --iterations "${VALIDATION_ITERATIONS}" --output "${out}" 2>&1 | tee "${SC4_LOG_DIR}/quad-${q}.log"
  ec=${PIPESTATUS[0]}
  took="$(( (SECONDS - start) / 60 ))m$(( (SECONDS - start) % 60 ))s"
  timed_out=0
  [[ ${ec} -eq 124 || ${ec} -eq 137 ]] && timed_out=1

  # Analyze whatever iterations finished, even after a timeout, so the job log
  # names the cause (missing or extra connections, ARC timeout, ...).
  cp -r "${out}" "${SC4_LOG_DIR}/quad-${q}" 2>/dev/null || true
  python3 tools/scaleout/exabox/analyze_validation_results.py --all "${out}" 2>&1 |
    sed 's/\x1b\[[0-9;]*m//g' | tee "${SC4_LOG_DIR}/quad-${q}-analysis.txt"
  verdict=${PIPESTATUS[0]}
  rate=$(grep -m1 -oE 'Success Rate: [0-9.]+%' "${SC4_LOG_DIR}/quad-${q}-analysis.txt")
  headline=$(grep -m1 -E '^VALIDATION (PASSED|FAILED)' "${SC4_LOG_DIR}/quad-${q}-analysis.txt")
  causes=$(grep -E '^[A-Za-z /]+: [1-9][0-9]* / [0-9]+' "${SC4_LOG_DIR}/quad-${q}-analysis.txt" |
    grep -vE '^(Healthy links|Total)' | sed 's/ *$//' | paste -sd';' - | sed 's/;/; /g')
  if [[ ${timed_out} -eq 1 ]]; then
    record FAIL "validation quad ${q}" "timed out after ${VALIDATION_TIMEOUT_MIN}m; finished iterations: ${rate:-none}${causes:+ (${causes})}"
    continue
  fi
  if [[ ${verdict} -eq 0 ]]; then
    record PASS "validation quad ${q}" "${rate:-?}, ${VALIDATION_ITERATIONS} iterations in ${took}"
  else
    record FAIL "validation quad ${q}" "analyzer exit ${verdict}: ${headline:-see quad-${q}-analysis.txt} (${took})"
  fi
done

summarize "SC4 validation (run_validation.sh, ${VALIDATION_ITERATIONS} iterations per quad)"
