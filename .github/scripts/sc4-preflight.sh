#!/usr/bin/env bash
# Preflight for the SC4 cluster tests. Runs on the starter (head) host and checks
# what tt-metal's tools/scaleout/exabox scripts need before they can drive the
# other hosts: passwordless SSH, Tenstorrent OpenMPI, Docker, the exabox-tools
# image and the scaleout descriptors.
#
# Every check runs even if an earlier one fails; the summary at the end lists
# them all and the script exits non-zero if any required check failed.
#
# Env:
#   SC4_QUADS           the quads, "name=h1,h2,h3,h4 ..." (see sc4-common.sh), or
#   SC4_HOSTS           comma-separated hosts to check (the starter included)
#   EXABOX_IMAGE        image the exabox scripts run (default exabox-tools:latest)
#   SCALEOUT_CONFIGS    descriptor directory (default /data/scaleout_configs)
#   SC4_FSD             factory system descriptor the per-quad FSDs are cut from
set -uo pipefail

if [[ -z "${SC4_HOSTS:-}" && -n "${SC4_QUADS:-}" ]]; then
  SC4_HOSTS="$(tr ' ' '\n' <<< "${SC4_QUADS}" | sed 's/^[^=]*=//' | grep . | paste -sd, -)"
fi
SC4_HOSTS="${SC4_HOSTS:?set SC4_QUADS or SC4_HOSTS}"
EXABOX_IMAGE="${EXABOX_IMAGE:-ghcr.io/tenstorrent/tt-metal/exabox-tools:latest}"
SCALEOUT_CONFIGS="${SCALEOUT_CONFIGS:-/data/scaleout_configs}"
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new)

IFS=',' read -r -a HOSTS <<< "${SC4_HOSTS}"
declare -a RESULTS=()
FAILED=0

record() { # record <PASS|FAIL|WARN> <check> <detail>
  RESULTS+=("$(printf '%-4s  %-40s  %s' "$1" "$2" "$3")")
  [[ "$1" == FAIL ]] && FAILED=1
  return 0
}

section() { echo; echo "=== $* ==="; }

section "Starter host"
echo "hostname: $(hostname)   user: $(id -un)   home: ${HOME}"
ls -la "${HOME}/.ssh" 2>&1 || true

section "Host name resolution"
for h in "${HOSTS[@]}"; do
  if addr=$(getent hosts "${h}"); then
    echo "${addr}"
    record PASS "resolve ${h}" "$(awk '{print $1}' <<< "${addr}")"
  else
    record FAIL "resolve ${h}" "getent hosts found nothing"
  fi
done

section "Passwordless SSH from $(hostname)"
for h in "${HOSTS[@]}"; do
  if out=$(timeout 30 ssh "${SSH_OPTS[@]}" "${h}" 'hostname; sudo -n true && echo sudo-ok' 2>&1); then
    echo "${h}: ${out//$'\n'/ }"
    if grep -q sudo-ok <<< "${out}"; then
      record PASS "ssh ${h}" "$(head -1 <<< "${out}")"
    else
      record FAIL "ssh ${h}" "connected, but passwordless sudo missing"
    fi
  else
    echo "${h}: ${out}"
    record FAIL "ssh ${h}" "$(tail -1 <<< "${out}")"
  fi
done

section "OpenMPI"
ls -d /opt/*mpi* 2>/dev/null || true
if command -v mpirun >/dev/null; then
  mpirun --version 2>&1 | head -2
  record PASS "mpirun on starter" "$(command -v mpirun)"
  if out=$(timeout 120 mpirun --host "${SC4_HOSTS}" hostname 2>&1); then
    echo "${out}"
    record PASS "mpirun --host <all> hostname" "$(wc -l <<< "${out}") ranks answered"
  else
    echo "${out}"
    record FAIL "mpirun --host <all> hostname" "$(tail -1 <<< "${out}")"
  fi
  if out=$(timeout 120 mpirun --host "${SC4_HOSTS}" docker --version 2>&1); then
    echo "${out}"
    record PASS "docker on all hosts" "via mpirun"
  else
    echo "${out}"
    record FAIL "docker on all hosts" "$(tail -1 <<< "${out}")"
  fi
else
  record FAIL "mpirun on starter" "not on PATH (needs tenstorrent/ompi v5.0.7)"
fi
command -v mpirun-ulfm >/dev/null && record PASS "mpirun-ulfm" "$(command -v mpirun-ulfm)" \
  || record WARN "mpirun-ulfm" "not found (Docker-based exabox scripts use it)"

section "Docker image ${EXABOX_IMAGE}"
if timeout 1800 docker pull -q "${EXABOX_IMAGE}"; then
  rev=$(docker inspect --format '{{index .Config.Labels "org.opencontainers.image.revision"}}' "${EXABOX_IMAGE}" 2>/dev/null)
  record PASS "pull exabox image" "tt-metal ${rev:-unknown revision}"
else
  record FAIL "pull exabox image" "docker pull failed (ghcr access / docker group?)"
fi

section "Scaleout descriptors in ${SCALEOUT_CONFIGS}"
if [[ -d "${SCALEOUT_CONFIGS}" ]]; then
  find "${SCALEOUT_CONFIGS}" -maxdepth 3 | sort | head -100
  record PASS "scaleout configs dir" "${SCALEOUT_CONFIGS}"
  for f in $(find "${SCALEOUT_CONFIGS}" -maxdepth 3 -name 'deployment_descriptor*.textproto' | sort); do
    echo "--- hosts in ${f} ---"
    grep -oE 'host(name)?:[[:space:]]*"[^"]+"' "${f}" | head -20 || true
  done
else
  record FAIL "scaleout configs dir" "${SCALEOUT_CONFIGS} missing on starter"
fi
if [[ -n "${SC4_FSD:-}" ]]; then
  if [[ -r "${SC4_FSD}" ]]; then
    record PASS "factory system descriptor" "${SC4_FSD} ($(grep -c '^hosts {' "${SC4_FSD}") hosts)"
  else
    record FAIL "factory system descriptor" "${SC4_FSD} not readable"
  fi
fi
for h in "${HOSTS[@]}"; do
  [[ "${h}" == "$(hostname)" ]] && continue
  if timeout 30 ssh "${SSH_OPTS[@]}" "${h}" "test -d '${SCALEOUT_CONFIGS}'" 2>/dev/null; then
    record PASS "scaleout configs on ${h}" "present"
  else
    record WARN "scaleout configs on ${h}" "missing or unreachable"
  fi
done

section "Summary"
printf '%s\n' "${RESULTS[@]}"
{
  echo "### SC4 preflight on $(hostname)"
  echo '```'
  printf '%s\n' "${RESULTS[@]}"
  echo '```'
} >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
exit "${FAILED}"
