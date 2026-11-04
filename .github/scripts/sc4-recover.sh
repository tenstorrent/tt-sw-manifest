#!/usr/bin/env bash
# Leave the SC4 hosts clean after the tests, whatever happened. Runs always.
#
# A timed-out mpirun can leave test containers behind on the other hosts, and a
# container that keeps /dev/tenstorrent open makes the next run wait on the KMD
# lock forever. So, on every host:
#   1. remove containers of ${EXABOX_IMAGE} that run as this CI user (mpi-docker
#      starts them with --user <uid>:<gid>; other people's containers are left alone)
#   2. tt-smi -glx_reset (a reset is enough to recover the trays)
#   3. report anything that still holds a device
#   4. delete this run's scratch directory
# Exits non-zero only when a host is still held or did not reset.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/sc4-common.sh"

pick_mpi_if || exit 1
RECOVER='h=$(hostname); me="$(id -u):$(id -g)";
for c in $(docker ps -q --filter "ancestor='"${EXABOX_IMAGE}"'"); do
  if [ "$(docker inspect -f "{{.Config.User}}" "$c")" = "$me" ]; then
    echo "[$h] removing leftover container $c"; docker rm -f "$c" >/dev/null;
  fi;
done;
if command -v tt-smi >/dev/null; then T=$(command -v tt-smi); S=""; else T=/root/.tenstorrent-venv/bin/tt-smi; S=sudo; fi;
script -qefc "$S $T -glx_reset" /dev/null > /tmp/sc4-recover-$h.log 2>&1; ec=$?;
p=$(sudo fuser /dev/tenstorrent/* 2>/dev/null | tr -s " " "\n" | grep -E "^[0-9]+$" | sort -u | paste -sd, -);
[ -n "$p" ] && echo "[$h] still HELD by: $(sudo ps -o pid=,user=,etime=,cmd= -p "$p" | cut -c1-150 | tr "\n" ";")";
sudo rm -rf "'"${SC4_SCRATCH}"'";
echo "RECOVER_RESULT|$h|reset=$ec|held=${p:-none}"'
on_all_hosts "${SC4_HOSTS}" "${RECOVER}" 2>&1 | tee "${SC4_LOG_DIR}/recover.log"

ok=$(grep -cE '^RECOVER_RESULT\|[^|]+\|reset=0\|held=none$' "${SC4_LOG_DIR}/recover.log")
bad=$(grep -E '^RECOVER_RESULT\|' "${SC4_LOG_DIR}/recover.log" | grep -vE 'reset=0\|held=none$' | cut -d'|' -f2- | paste -sd' ' -)
if [[ "${ok}" -eq "${NHOSTS}" ]]; then
  record PASS "recover (reset, no holders)" "${ok}/${NHOSTS} hosts"
else
  record FAIL "recover (reset, no holders)" "${ok}/${NHOSTS} clean; ${bad:-missing results}"
fi
summarize "SC4 recover"
