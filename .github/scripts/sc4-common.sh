#!/usr/bin/env bash
# Shared helpers for the SC4 cluster scripts (sc4-*.sh). Source it; do not run it.
#
# Env (set by golden-sc4-cluster.yml):
#   SC4_QUADS     the quads, "name=host,host,host,host" separated by spaces,
#                 each in physical ring order, e.g.
#                 "A=h1,h2,h3,h4 B=h5,h6,h7,h8". All hosts = every quad's hosts.
#   EXABOX_IMAGE  tt-metal image with the test binaries and exabox scripts
#   SC4_LOG_DIR   where logs go
#   SC4_QUAD_FSD_DIR  committed per-quad FSDs (fsd-quad-<name>.textproto). A quad
#                 with a file here uses it; any other quad is cut from SC4_FSD.
#   SC4_FSD       full factory system descriptor to cut per-quad subsets from
#   MPI_IF        MPI network interface (default: the route to a peer)

# The SC hosts default to umask 027. Files we hand to containers (which run as
# the invoking user, but read through bind mounts) or to other users must be
# world-readable.
umask 022

SC4_QUADS="${SC4_QUADS:?set SC4_QUADS to 'name=h1,h2,h3,h4 ...'}"
EXABOX_IMAGE="${EXABOX_IMAGE:?}"
SC4_LOG_DIR="${SC4_LOG_DIR:-$(pwd)/sc4-logs}"
SC4_FSD="${SC4_FSD:-/data/scaleout_configs/tt-cluster-config-sources/exabox-latest-main/factory_system_descriptor.textproto}"
SC4_SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SC4_QUAD_FSD_DIR="${SC4_QUAD_FSD_DIR:-$(cd "${SC4_SCRIPTS}/../sc4" 2>/dev/null && pwd)}"
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new)
mkdir -p "${SC4_LOG_DIR}"

declare -A QUAD_HOSTS=()
QUAD_NAMES=()
for q in ${SC4_QUADS}; do
  QUAD_NAMES+=("${q%%=*}")
  QUAD_HOSTS["${q%%=*}"]="${q#*=}"
done
SC4_HOSTS="$(for q in "${QUAD_NAMES[@]}"; do echo "${QUAD_HOSTS[$q]}"; done | paste -sd, -)"
NHOSTS=$(tr ',' '\n' <<< "${SC4_HOSTS}" | grep -c .)

# Per-run scratch directory on every host. /tmp is bind-mounted into the
# mpi-docker containers, so descriptors staged here are visible to every rank.
SC4_SCRATCH="/tmp/sc4-ci-${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-0}"

declare -a RESULTS=()
FAILED=0
record() { # record <PASS|FAIL|WARN> <check> <detail>
  RESULTS+=("$(printf '%-4s  %-34s  %s' "$1" "$2" "$3")")
  [[ "$1" == FAIL ]] && FAILED=1
  return 0
}

# Print the results and add them to the job summary. Returns FAILED.
summarize() { # summarize <title>
  echo; echo "=== Summary: $1 ==="
  printf '%s\n' "${RESULTS[@]}"
  {
    echo "### $1"
    echo '```'
    printf '%s\n' "${RESULTS[@]}"
    echo '```'
  } >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
  return "${FAILED}"
}

# Pick the interface the kernel routes to a peer over, unless MPI_IF is set.
# tt-metal's validate_mpi_interface auto-detection rejected every interface on
# these hosts and hides why, so always hand the exabox scripts an explicit one.
pick_mpi_if() {
  if [[ -z "${MPI_IF:-}" ]]; then
    local peer peer_ip
    peer=$(tr ',' '\n' <<< "${SC4_HOSTS}" | grep -vx "$(hostname)" | head -1)
    peer_ip=$(getent hosts "${peer}" | awk '{print $1; exit}')
    MPI_IF=$(ip route get "${peer_ip}" | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -1)
  fi
  [[ -n "${MPI_IF}" ]] || { echo "ERROR: could not pick an MPI interface" >&2; return 1; }
  export MPI_IF
  echo "MPI interface: ${MPI_IF}"
}

# Run a bash snippet once on every host (one rank per host).
on_all_hosts() { # on_all_hosts <hosts-csv> <bash snippet>
  local hosts="$1" n
  n=$(tr ',' '\n' <<< "${hosts}" | grep -c .)
  mpirun --host "${hosts}" -np "${n}" --mca btl_tcp_if_include "${MPI_IF}" bash -c "$2"
}

# Copy the exabox scripts out of the image, so they always match its binaries.
# Run the exabox scripts from ${EXABOX_ROOT}: they call ./tools/scaleout/exabox/...
stage_exabox() {
  EXABOX_ROOT="${GITHUB_WORKSPACE:-$(pwd)}/exabox-${EXABOX_IMAGE##*:}"
  mkdir -p "${EXABOX_ROOT}"
  if [[ ! -x "${EXABOX_ROOT}/tools/scaleout/exabox/run_validation.sh" ]]; then
    local c
    c=$(docker create "${EXABOX_IMAGE}") || return 1
    mkdir -p "${EXABOX_ROOT}/tools/scaleout"
    docker cp -q "${c}:/home/user/tt-metal/tools/scaleout/exabox" "${EXABOX_ROOT}/tools/scaleout/"
    local rc=$?
    docker rm "${c}" > /dev/null
    [[ ${rc} -eq 0 ]] || return 1
  fi
  export EXABOX_ROOT
  echo "exabox scripts from ${EXABOX_IMAGE}: ${EXABOX_ROOT}"
}

# Where a quad's FSD comes from: the committed file if there is one, else the
# full FSD cut down to the quad's hosts.
quad_fsd_source() { # quad_fsd_source <quad-name>
  local f="${SC4_QUAD_FSD_DIR}/fsd-quad-$1.textproto"
  if [[ -n "${SC4_QUAD_FSD_DIR}" && -f "${f}" ]]; then echo "${f}"; else echo "${SC4_FSD} (cut to quad $1)"; fi
}

# Put one quad's FSD at the same path on each of its hosts. Prints that path.
stage_quad_fsd() { # stage_quad_fsd <quad-name>
  local name="$1" hosts="${QUAD_HOSTS[$1]}" out="${SC4_SCRATCH}/fsd-$1.textproto" h
  local committed="${SC4_QUAD_FSD_DIR}/fsd-quad-$1.textproto"
  mkdir -p -m 755 "${SC4_SCRATCH}"
  if [[ -n "${SC4_QUAD_FSD_DIR}" && -f "${committed}" ]]; then
    # The committed file must list exactly the quad's hosts, in quad order.
    local listed
    listed=$(sed -n 's/^ *hostname: *"\([^"]*\)".*/\1/p' "${committed}" | paste -sd, -)
    if [[ "${listed}" != "${hosts}" ]]; then
      echo "ERROR: ${committed} lists hosts ${listed}, but quad ${name} is ${hosts}" >&2
      return 1
    fi
    cp "${committed}" "${out}"
    echo "quad ${name} FSD: ${committed}" >&2
  else
    python3 -I "${SC4_SCRIPTS}/fsd-subset.py" "${SC4_FSD}" "${hosts}" "${out}" >&2 || return 1
  fi
  chmod 644 "${out}"
  for h in ${hosts//,/ }; do
    [[ "${h}" == "$(hostname)" ]] && continue
    ssh "${SSH_OPTS[@]}" "${h}" "mkdir -p -m 755 '${SC4_SCRATCH}'" &&
      scp -q -p "${SSH_OPTS[@]}" "${out}" "${h}:${out}" || { echo "ERROR: could not copy FSD to ${h}" >&2; return 1; }
  done
  cp "${out}" "${SC4_LOG_DIR}/"
  echo "${out}"
}
