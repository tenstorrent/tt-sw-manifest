#!/usr/bin/env bash
# SC4 health: check that nothing else holds the devices, reset every host, then
# run physical discovery and the system health check across all of them. Same
# binaries as tt-metal's "SC4 physical discovery, health, stability, and DC
# validation" job (tests/pipeline_reorg/fabric_multihost_exabox_tests.yaml),
# launched with tools/scaleout/exabox/mpi-docker over SSH instead of Kubernetes.
#
# Env: see sc4-common.sh, plus
#   MIN_CONNECTIONS   test_system_health --min-connections (default 2)
#   TEST_TIMEOUT_MIN  timeout per test (default 20)
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/sc4-common.sh"

MIN_CONNECTIONS="${MIN_CONNECTIONS:-2}"
TEST_TIMEOUT_MIN="${TEST_TIMEOUT_MIN:-20}"

pick_mpi_if || exit 1
echo "hosts (${NHOSTS}): ${SC4_HOSTS}"
ip -br addr show "${MPI_IF}" || true
stage_exabox || { echo "ERROR: could not copy the exabox scripts out of ${EXABOX_IMAGE}" >&2; exit 1; }

echo "=== Device holders and hugepages on every host ==="
# A process that keeps /dev/tenstorrent/* open (a pod, a stale container, an
# old test) makes the tests wait on the KMD lock forever. /proc is mounted with
# hidepid on these hosts, so look the holder up with sudo.
HOLDERS='h=$(hostname); p=$(sudo fuser /dev/tenstorrent/* 2>/dev/null | tr -s " " "\n" | grep -E "^[0-9]+$" | sort -u | paste -sd" " -);
hp=$(awk "/HugePages_Total/ {print \$2}" /proc/meminfo);
if [ -n "$p" ]; then
  echo "[$h] HELD by: $(sudo ps -o pid=,ppid=,user=,lstart=,etime=,cmd= -p "${p// /,}" | cut -c1-200 | tr "\n" ";")";
  sudo fuser -v /dev/tenstorrent/* 2>&1 | sed "s/^/[$h] fuser: /";
  for q in $p; do echo "[$h] cgroup $q: $(sudo cat /proc/$q/cgroup 2>/dev/null | tr "\n" " ")"; done;
fi;
echo "HOLD_RESULT|$h|${p:-none}|hugepages=${hp}"'
on_all_hosts "${SC4_HOSTS}" "${HOLDERS}" 2>&1 | tee "${SC4_LOG_DIR}/device_holders.log"
held=$(grep -E '^HOLD_RESULT\|' "${SC4_LOG_DIR}/device_holders.log" | awk -F'|' '$3 != "none" {print $2}' | paste -sd, -)
nohp=$(grep -E '^HOLD_RESULT\|' "${SC4_LOG_DIR}/device_holders.log" | awk -F'|' '$4 == "hugepages=0" {print $2}' | paste -sd, -)
if [[ -n "${held}" ]]; then
  record FAIL "free devices" "in use on: ${held} (see device_holders.log)"
  summarize "SC4 health on ${SC4_HOSTS}"
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
on_all_hosts "${SC4_HOSTS}" "${RESET}" 2>&1 | tee "${SC4_LOG_DIR}/reset.log"
bad=$(grep -E '^RESET_RESULT\|' "${SC4_LOG_DIR}/reset.log" | awk -F'|' '$3 != 0 {print $2}' | paste -sd, -)
ok=$(grep -cE '^RESET_RESULT\|[^|]+\|0$' "${SC4_LOG_DIR}/reset.log")
if [[ -z "${bad}" && "${ok}" -eq "${NHOSTS}" ]]; then
  record PASS "glx reset" "${ok}/${NHOSTS} hosts"
else
  record FAIL "glx reset" "${ok}/${NHOSTS} ok; failed: ${bad:-missing results}"
fi

run_test() { # run_test <name> <binary> [args...]
  local name="$1" start=${SECONDS} ec; shift
  echo; echo "=== ${name} (timeout ${TEST_TIMEOUT_MIN}m) ==="
  timeout --kill-after=60 "${TEST_TIMEOUT_MIN}m" "${EXABOX_ROOT}/tools/scaleout/exabox/mpi-docker" \
    --image "${EXABOX_IMAGE}" --empty-entrypoint --tag-host \
    --mpi-interface "${MPI_IF}" --volume /data/scaleout_configs \
    --host "${SC4_HOSTS}" -np "${NHOSTS}" \
    "$@" 2>&1 | tee "${SC4_LOG_DIR}/${name}.log"
  ec=${PIPESTATUS[0]}
  if [[ "${ec}" -eq 0 ]]; then
    record PASS "${name}" "exit 0 in $(( SECONDS - start ))s"
  elif [[ "${ec}" -eq 124 || "${ec}" -eq 137 ]]; then
    record FAIL "${name}" "timed out after ${TEST_TIMEOUT_MIN}m (a host stalled; see ${name}.log)"
  else
    record FAIL "${name}" "exit ${ec} (see ${name}.log)"
  fi
}

run_test physical_discovery ./build/test/tt_metal/tt_fabric/test_physical_discovery
run_test system_health ./build/test/tt_metal/tt_fabric/test_system_health --min-connections "${MIN_CONNECTIONS}"

summarize "SC4 health on ${SC4_HOSTS}"
