#!/usr/bin/env bash
# SC4 health: reset every host, then run physical discovery and the system
# health check across all of them from the exabox-tools image. Same binaries as
# tt-metal's "SC4 physical discovery, health, stability, and DC validation"
# job (tests/pipeline_reorg/fabric_multihost_exabox_tests.yaml), launched with
# tools/scaleout/exabox/mpi-docker over SSH instead of Kubernetes.
#
# Run from the root of a tt-metal checkout that matches the image.
#
# Env:
#   SC4_HOSTS        comma-separated hosts (one rank per host)
#   EXABOX_IMAGE     exabox-tools image
#   SC4_LOG_DIR      where logs go (default ./sc4-logs)
#   MIN_CONNECTIONS  test_system_health --min-connections (default 2)
#   MPI_IF           MPI network interface (auto-detected if unset)
set -uo pipefail

SC4_HOSTS="${SC4_HOSTS:?}"
EXABOX_IMAGE="${EXABOX_IMAGE:?}"
SC4_LOG_DIR="${SC4_LOG_DIR:-$(pwd)/sc4-logs}"
MIN_CONNECTIONS="${MIN_CONNECTIONS:-2}"
TEST_TIMEOUT_MIN="${TEST_TIMEOUT_MIN:-20}"
EXABOX=tools/scaleout/exabox
NHOSTS=$(tr ',' '\n' <<< "${SC4_HOSTS}" | grep -c .)
mkdir -p "${SC4_LOG_DIR}"

declare -a RESULTS=()
FAILED=0
record() {
  RESULTS+=("$(printf '%-4s  %-30s  %s' "$1" "$2" "$3")")
  [[ "$1" == FAIL ]] && FAILED=1
  return 0
}

# Pick the interface the kernel routes to a peer over. tt-metal's
# validate_mpi_interface rejected every interface on these hosts and hides why,
# so test it here with the output visible.
PEER=$(tr ',' '\n' <<< "${SC4_HOSTS}" | grep -vx "$(hostname)" | head -1)
PEER_IP=$(getent hosts "${PEER}" | awk '{print $1; exit}')
if [[ -z "${MPI_IF:-}" ]]; then
  MPI_IF=$(ip route get "${PEER_IP}" | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -1)
fi
[[ -n "${MPI_IF}" ]] || { echo "ERROR: could not pick an MPI interface" >&2; exit 1; }
echo "MPI interface: ${MPI_IF} (route to ${PEER} ${PEER_IP})   hosts (${NHOSTS}): ${SC4_HOSTS}"
ip -br addr show "${MPI_IF}" || true
echo "--- mpirun reachability test over ${MPI_IF} ---"
for launcher in mpirun mpirun-ulfm; do
  command -v "${launcher}" >/dev/null || continue
  echo "[${launcher}] $(command -v "${launcher}")"
  timeout 60 "${launcher}" --host "${PEER}" --mca oob_tcp_if_include "${MPI_IF}" \
    --mca btl_tcp_if_include "${MPI_IF}" -np 1 hostname 2>&1 | tail -15
  echo "[${launcher}] exit ${PIPESTATUS[0]}"
done

echo "=== Device holders and hugepages on every host ==="
# A process that keeps /dev/tenstorrent/* open (a pod, a stale container, an
# old test) makes the tests wait on the KMD lock forever.
HOLDERS='h=$(hostname); p=$(sudo fuser /dev/tenstorrent/* 2>/dev/null | tr -s " " "\n" | grep -E "^[0-9]+$" | sort -u | paste -sd" " -);
hp=$(awk "/HugePages_Total/ {print \$2}" /proc/meminfo);
if [ -n "$p" ]; then echo "[$h] HELD by: $(ps -o pid=,user=,etime=,cmd= -p "${p// /,}" | cut -c1-150 | tr "\n" ";")"; fi;
echo "HOLD_RESULT|$h|${p:-none}|hugepages=${hp}"'
mpirun --host "${SC4_HOSTS}" -np "${NHOSTS}" --mca btl_tcp_if_include "${MPI_IF}" \
  bash -c "${HOLDERS}" 2>&1 | tee "${SC4_LOG_DIR}/device_holders.log"
held=$(grep -E '^HOLD_RESULT\|' "${SC4_LOG_DIR}/device_holders.log" | awk -F'|' '$3 != "none" {print $2}' | paste -sd, -)
nohp=$(grep -E '^HOLD_RESULT\|' "${SC4_LOG_DIR}/device_holders.log" | awk -F'|' '$4 == "hugepages=0" {print $2}' | paste -sd, -)
if [[ -n "${held}" ]]; then
  record FAIL "free devices" "in use on: ${held} (see device_holders.log)"
  echo; printf '%s\n' "${RESULTS[@]}"
  echo "ERROR: another process holds Tenstorrent devices on ${held}; not starting tests." >&2
  exit 1
fi
record PASS "free devices" "no other process has /dev/tenstorrent open"
[[ -n "${nohp}" ]] && record WARN "hugepages" "none reserved on: ${nohp}"

echo "=== tt-smi -glx_reset on every host ==="
# Hosts may have tt-smi on the user's PATH or only in the root venv the golden
# install creates; use whichever exists.
RESET='h=$(hostname); if command -v tt-smi >/dev/null; then T=$(command -v tt-smi); S=""; else T=/root/.tenstorrent-venv/bin/tt-smi; S=sudo; fi;
echo "[$h] using $S $T"; script -qefc "$S $T -glx_reset" /dev/null > /tmp/sc4-reset-$h.log 2>&1; ec=$?;
tail -3 /tmp/sc4-reset-$h.log | tr -d "\r" | sed "s/^/[$h] /"; echo "RESET_RESULT|$h|$ec"'
mpirun --host "${SC4_HOSTS}" -np "${NHOSTS}" --mca btl_tcp_if_include "${MPI_IF}" \
  bash -c "${RESET}" 2>&1 | tee "${SC4_LOG_DIR}/reset.log"
bad=$(grep -E '^RESET_RESULT\|' "${SC4_LOG_DIR}/reset.log" | awk -F'|' '$3 != 0 {print $2}' | paste -sd, -)
ok=$(grep -cE '^RESET_RESULT\|[^|]+\|0$' "${SC4_LOG_DIR}/reset.log")
if [[ -z "${bad}" && "${ok}" -eq "${NHOSTS}" ]]; then
  record PASS "glx reset" "${ok}/${NHOSTS} hosts"
else
  record FAIL "glx reset" "${ok}/${NHOSTS} ok; failed: ${bad:-missing results}"
fi

run_test() { # run_test <name> <binary> [args...]
  local name="$1"; shift
  echo; echo "=== ${name} (timeout ${TEST_TIMEOUT_MIN}m) ==="
  timeout --kill-after=60 "${TEST_TIMEOUT_MIN}m" "${EXABOX}/mpi-docker" --image "${EXABOX_IMAGE}" --empty-entrypoint --tag-host \
    --mpi-interface "${MPI_IF}" --volume /data/scaleout_configs \
    --host "${SC4_HOSTS}" -np "${NHOSTS}" \
    "$@" 2>&1 | tee "${SC4_LOG_DIR}/${name}.log"
  local ec=${PIPESTATUS[0]}
  if [[ "${ec}" -eq 0 ]]; then
    record PASS "${name}" "exit 0"
  elif [[ "${ec}" -eq 124 || "${ec}" -eq 137 ]]; then
    record FAIL "${name}" "timed out after ${TEST_TIMEOUT_MIN}m (a host stalled; see ${name}.log)"
  else
    record FAIL "${name}" "exit ${ec} (see ${name}.log)"
  fi
}

run_test physical_discovery ./build/test/tt_metal/tt_fabric/test_physical_discovery
run_test system_health ./build/test/tt_metal/tt_fabric/test_system_health --min-connections "${MIN_CONNECTIONS}"

echo; echo "=== Scaleout descriptors that mention these hosts ==="
pattern=$(tr ',' '\n' <<< "${SC4_HOSTS}" | sed 's/[.]/\\./g' | paste -sd'|' -)
timeout 300 grep -rlE --include='*.textproto' "${pattern}" /data/scaleout_configs 2>/dev/null \
  | tee "${SC4_LOG_DIR}/matching_descriptors.txt" || echo "(none found)"

echo; echo "=== Summary ==="
printf '%s\n' "${RESULTS[@]}"
{
  echo "### SC4 health on ${SC4_HOSTS}"
  echo '```'
  printf '%s\n' "${RESULTS[@]}"
  echo '```'
} >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
exit "${FAILED}"
