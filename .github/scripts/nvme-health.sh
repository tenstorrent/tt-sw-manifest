#!/usr/bin/env bash
# Snapshot and compare host NVMe / RAID health across a reset.
#
# smi-reset.sh runs this on BH Galaxy (bh-galaxy*) so tt-smi -glx_reset fails
# when a reset drops E1.S drives. The checks are the ones used to validate the
# no-retimer Galaxy reset: drive identity, PCI address, RAID health and member
# serials, failed-disk markers, read-write mounts, and new NVMe/RAID/PCIe-drop
# lines in dmesg.
#
#   nvme-health.sh snapshot <dir>
#   nvme-health.sh summary <dir>
#   nvme-health.sh mark <marker-file>
#   nvme-health.sh settle <before-dir> <after-dir>
#   nvme-health.sh collect-dmesg <marker-file> <out-file>
#   nvme-health.sh compare <before-dir> <after-dir>
#   nvme-health.sh self-test
set -euo pipefail

usage() {
  echo "Usage: nvme-health.sh snapshot|summary|mark|settle|collect-dmesg|compare|self-test ..." >&2
  exit 2
}

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

count_chips() {
  local n=0 dev
  shopt -s nullglob
  for dev in /dev/tenstorrent/[0-9]*; do
    [[ -e "${dev}" ]] || continue
    n=$((n + 1))
  done
  shopt -u nullglob
  printf '%s\n' "${n}"
}

# Read mdstat-like text on stdin. One TSV line per array:
#   name  level  [n/m]  [bitmap]  failed
parse_mdstat_text() {
  local line dev="" level=""
  while IFS= read -r line || [[ -n "${line}" ]]; do
    if [[ "${line}" =~ ^(md[0-9]+)[[:space:]]*:[[:space:]]*inactive ]]; then
      printf '%s\tinactive\t[0/0]\t[]\t1\n' "${BASH_REMATCH[1]}"
      dev=""
      continue
    fi
    if [[ "${line}" =~ ^(md[0-9]+)[[:space:]]*:[[:space:]]*active[[:space:]]+(raid[0-9]+) ]]; then
      dev="${BASH_REMATCH[1]}"
      level="${BASH_REMATCH[2]}"
      continue
    fi
    if [[ -n "${dev}" && "${line}" =~ \[([0-9]+)/([0-9]+)\][[:space:]]+\[([U_F]+)\] ]]; then
      local n="${BASH_REMATCH[1]}"
      local m="${BASH_REMATCH[2]}"
      local bitmap="${BASH_REMATCH[3]}"
      local failed=$((n - m))
      printf '%s\t%s\t[%s/%s]\t[%s]\t%s\n' "${dev}" "${level}" "${n}" "${m}" "${bitmap}" "${failed}"
      dev=""
    fi
  done | sort
}

nvme_serial_for_block() {
  local slave="$1"
  local block="/sys/block/${slave}"
  local path
  for path in \
    "${block}/device/serial" \
    "${block}/device/device/serial" \
    "${block}/device/device/device/serial"
  do
    if [[ -r "${path}" ]]; then
      trim "$(cat "${path}")"
      return 0
    fi
  done
  printf 'unknown-%s' "${slave}"
}

write_raid_members() {
  local out="$1"
  : > "${out}"
  [[ -r /proc/mdstat ]] || return 0
  local md slave serials serial
  shopt -s nullglob
  for md in /sys/block/md*; do
    [[ -d "${md}/slaves" ]] || continue
    serials=""
    for slave in "${md}/slaves"/*; do
      [[ -e "${slave}" ]] || continue
      serial="$(nvme_serial_for_block "$(basename "${slave}")")"
      serials+="${serial}"$'\n'
    done
    serials="$(printf '%s' "${serials}" | sed '/^$/d' | sort | paste -sd',' -)"
    printf '%s\t%s\n' "$(basename "${md}")" "${serials}"
  done | sort > "${out}.tmp"
  shopt -u nullglob
  mv "${out}.tmp" "${out}"
}

write_mounts() {
  local out="$1"
  : > "${out}"
  [[ -r /proc/mounts ]] || return 0
  local src mnt fstype opts rest real mode
  while read -r src mnt fstype opts rest; do
    real="$(readlink -f "${src}" 2>/dev/null || true)"
    case "${real}" in
      /dev/nvme* | /dev/md*) ;;
      *) continue ;;
    esac
    mode=rw
    case ",${opts}," in
      *,ro,*) mode=ro ;;
    esac
    # Only mounts that were writable are required to stay writable.
    [[ "${mode}" == rw ]] || continue
    printf '%s\t%s\n' "${mode}" "${mnt}"
  done < /proc/mounts | sort -k2 > "${out}.tmp"
  mv "${out}.tmp" "${out}"
}

cmd_snapshot() {
  local out="${1:-}"
  [[ -n "${out}" ]] || usage
  local tmp
  tmp="$(mktemp -d)"

  : > "${tmp}/identity"
  : > "${tmp}/pci"
  local count=0
  local ctrl name serial model bdf ns sectors bytes saw_ns
  shopt -s nullglob
  for ctrl in /sys/class/nvme/nvme*; do
    [[ -d "${ctrl}" ]] || continue
    name="$(basename "${ctrl}")"
    if [[ -r "${ctrl}/serial" ]]; then
      serial="$(trim "$(cat "${ctrl}/serial")")"
    else
      serial="unknown-${name}"
    fi
    if [[ -r "${ctrl}/model" ]]; then
      model="$(trim "$(tr -s '[:space:]' ' ' < "${ctrl}/model")")"
    else
      model="unknown"
    fi
    if [[ -L "${ctrl}/device" ]]; then
      bdf="$(basename "$(readlink -f "${ctrl}/device")")"
    else
      bdf="unknown-${name}"
    fi
    printf '%s\n' "${bdf}" >> "${tmp}/pci"
    saw_ns=0
    for ns in /sys/class/block/"${name}"n*; do
      [[ -f "${ns}/size" ]] || continue
      saw_ns=1
      sectors="$(cat "${ns}/size")"
      bytes=$((sectors * 512))
      printf '%s\t%s\t%s\t%s\n' "${serial}" "${model}" "$(basename "${ns}")" "${bytes}" >> "${tmp}/identity"
    done
    if [[ "${saw_ns}" -eq 0 ]]; then
      printf '%s\t%s\t-\t0\n' "${serial}" "${model}" >> "${tmp}/identity"
    fi
    count=$((count + 1))
  done
  shopt -u nullglob

  sort -o "${tmp}/identity" "${tmp}/identity"
  sort -u -o "${tmp}/pci" "${tmp}/pci"
  printf '%s\n' "${count}" > "${tmp}/nvme-count"
  count_chips > "${tmp}/chips"

  if [[ -r /proc/mdstat ]]; then
    parse_mdstat_text < /proc/mdstat > "${tmp}/raid"
  else
    : > "${tmp}/raid"
  fi
  write_raid_members "${tmp}/raid-members"
  write_mounts "${tmp}/mounts"

  rm -rf "${out}"
  mkdir -p "$(dirname "${out}")"
  mv "${tmp}" "${out}"
}

summary_line() {
  local dir="$1"
  local count name level health bitmap failed parts=""
  count="$(cat "${dir}/nvme-count")"
  if [[ -s "${dir}/raid" ]]; then
    while IFS=$'\t' read -r name level health bitmap failed; do
      [[ -n "${name}" ]] || continue
      if [[ -n "${parts}" ]]; then
        parts+=", "
      fi
      parts+="${name} ${level} ${health} ${bitmap} failed=${failed}"
    done < "${dir}/raid"
  else
    parts="no RAID"
  fi
  printf '%s NVMe, %s' "${count}" "${parts}"
}

cmd_summary() {
  local dir="${1:-}"
  [[ -n "${dir}" && -d "${dir}" ]] || usage
  summary_line "${dir}"
  printf '\n'
}

cmd_mark() {
  local out="${1:-}"
  [[ -n "${out}" ]] || usage
  local marker="nvme-health-marker-$$-$(date +%s%N)"
  mkdir -p "$(dirname "${out}")"
  printf '%s\n' "${marker}" > "${out}"
  date '+%Y-%m-%d %H:%M:%S' > "${out}.since"
  if [[ -w /dev/kmsg ]]; then
    printf '<6>%s\n' "${marker}" > /dev/kmsg || true
  fi
}

snapshots_settled() {
  local before="$1" after="$2"
  cmp -s "${before}/identity" "${after}/identity" || return 1
  cmp -s "${before}/pci" "${after}/pci" || return 1
  local before_chips after_chips
  before_chips="$(cat "${before}/chips")"
  after_chips="$(cat "${after}/chips")"
  if [[ "${before_chips}" != "0" && "${before_chips}" != "${after_chips}" ]]; then
    return 1
  fi
  if [[ -s "${before}/raid" ]] && ! cmp -s "${before}/raid" "${after}/raid"; then
    return 1
  fi
  if [[ -s "${before}/raid-members" ]] && ! cmp -s "${before}/raid-members" "${after}/raid-members"; then
    return 1
  fi
  return 0
}

cmd_settle() {
  local before="${1:-}" after="${2:-}"
  [[ -n "${before}" && -n "${after}" && -d "${before}" ]] || usage
  # Poll until chips and drives look like the pre-reset snapshot, then wait
  # once more and snapshot again. A drive can drop a few seconds after the
  # reset command returns; stopping at the first match would hide that.
  local timeout="${NVME_DISCOVER_SECS:-60}"
  local post="${NVME_POST_RESET_SECS:-10}"
  local deadline=$((SECONDS + timeout))
  while true; do
    cmd_snapshot "${after}"
    if snapshots_settled "${before}" "${after}"; then
      break
    fi
    if (( SECONDS >= deadline )); then
      break
    fi
    sleep 2
  done
  if [[ "${post}" != "0" ]]; then
    sleep "${post}"
  fi
  cmd_snapshot "${after}"
}

cmd_collect_dmesg() {
  local marker_file="${1:-}" out="${2:-}"
  [[ -n "${marker_file}" && -n "${out}" && -f "${marker_file}" ]] || usage
  local marker since raw
  marker="$(cat "${marker_file}")"
  since=""
  if [[ -f "${marker_file}.since" ]]; then
    since="$(cat "${marker_file}.since")"
  fi
  raw="$(mktemp)"
  if [[ -n "${since}" ]] && dmesg -T --since "${since}" > "${raw}" 2>/dev/null; then
    :
  elif ! dmesg -T > "${raw}" 2>/dev/null; then
    dmesg > "${raw}" 2>/dev/null || : > "${raw}"
  fi
  if grep -qF "${marker}" "${raw}"; then
    awk -v m="${marker}" 'found { print } index($0, m) { found = 1 }' "${raw}" > "${out}"
  else
    cp "${raw}" "${out}"
  fi
  rm -f "${raw}"
}

pass() { printf 'PASS  %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; }

show_diff() {
  local label="$1" before="$2" after="$3"
  local missing extra
  missing="$(comm -23 "${before}" "${after}" || true)"
  extra="$(comm -13 "${before}" "${after}" || true)"
  if [[ -n "${missing}" ]]; then
    printf '  missing %s:\n' "${label}"
    printf '%s\n' "${missing}" | sed -n '1,20s/^/    /p'
  fi
  if [[ -n "${extra}" ]]; then
    printf '  unexpected %s:\n' "${label}"
    printf '%s\n' "${extra}" | sed -n '1,20s/^/    /p'
  fi
}

check_identity() {
  local before="$1" after="$2"
  local name="NVMe drive identities (serial/model/size)"
  if cmp -s "${before}/identity" "${after}/identity"; then
    pass "${name}"
    if [[ ! -s "${before}/identity" ]]; then
      echo "  note: no NVMe devices before reset; a dropped drive would not be visible"
    fi
    return 0
  fi
  fail "${name}"
  show_diff "drives" "${before}/identity" "${after}/identity"
  return 1
}

check_pci() {
  local before="$1" after="$2"
  local name="NVMe PCI addresses"
  if cmp -s "${before}/pci" "${after}/pci"; then
    pass "${name}"
    return 0
  fi
  fail "${name}"
  show_diff "PCI addresses" "${before}/pci" "${after}/pci"
  return 1
}

check_raid_health() {
  local before="$1" after="$2"
  local name="RAID health"
  if cmp -s "${before}/raid" "${after}/raid"; then
    pass "${name}"
    return 0
  fi
  fail "${name}"
  show_diff "RAID arrays" "${before}/raid" "${after}/raid"
  return 1
}

check_raid_members() {
  local before="$1" after="$2"
  local name="RAID member serials"
  if cmp -s "${before}/raid-members" "${after}/raid-members"; then
    pass "${name}"
    return 0
  fi
  fail "${name}"
  show_diff "RAID members" "${before}/raid-members" "${after}/raid-members"
  return 1
}

check_failed_markers() {
  local after="$1"
  local name="no RAID failed-disk markers after reset"
  local bad="" name_md level health bitmap failed
  if [[ -s "${after}/raid" ]]; then
    while IFS=$'\t' read -r name_md level health bitmap failed; do
      [[ -n "${name_md}" ]] || continue
      if [[ "${failed}" != "0" || "${bitmap}" == *[_F]* || "${health}" == *"(F)"* ]]; then
        bad+="${name_md} ${level} ${health} ${bitmap} failed=${failed}"$'\n'
      fi
    done < "${after}/raid"
  fi
  if [[ -z "${bad}" ]]; then
    pass "${name}"
    return 0
  fi
  fail "${name}"
  printf '%s' "${bad}" | sed 's/^/    /'
  return 1
}

check_mounts() {
  local before="$1" after="$2"
  local name="tracked mounts are not read-only"
  local mode mnt after_mode found bad=""
  if [[ ! -s "${before}/mounts" ]]; then
    pass "${name}"
    return 0
  fi
  while IFS=$'\t' read -r mode mnt; do
    [[ -n "${mnt}" ]] || continue
    found=0
    after_mode=""
    while IFS=$'\t' read -r after_mode mnt_after; do
      if [[ "${mnt_after}" == "${mnt}" ]]; then
        found=1
        break
      fi
    done < "${after}/mounts"
    if [[ "${found}" -eq 0 ]]; then
      bad+="unmounted ${mnt}"$'\n'
    elif [[ "${after_mode}" != "rw" ]]; then
      bad+="read-only ${mnt}"$'\n'
    fi
  done < "${before}/mounts"
  if [[ -z "${bad}" ]]; then
    pass "${name}"
    return 0
  fi
  fail "${name}"
  printf '%s' "${bad}" | sed 's/^/    /'
  return 1
}

dmesg_is_relevant() {
  local line="$1" bdf_re="$2"
  [[ "${line}" =~ [Nn][Vv][Mm][Ee] ]] && return 0
  [[ "${line}" =~ md/raid ]] && return 0
  [[ "${line}" =~ (^|[[:space:]])md: ]] && return 0
  if [[ -n "${bdf_re}" && "${line}" =~ ${bdf_re} ]]; then
    return 0
  fi
  return 1
}

dmesg_is_drop() {
  local line="$1"
  [[ "${line}" =~ I/O\ error|Buffer\ I/O\ error|controller\ is\ down|Device\ not\ ready|resetting\ controller|Removing|link\ down|PCIe\ Bus\ Error|AER:|Disk\ failure|kicked\ from\ array|offline\ device|probe\ failure ]]
}

check_dmesg() {
  local after="$1" pci="$2"
  local name="no new NVMe/RAID/PCIe-drop signatures in dmesg"
  local file="${after}/dmesg-new"
  if [[ ! -f "${file}" ]]; then
    fail "${name}"
    echo "    dmesg capture missing"
    return 1
  fi
  local bdf_re="" line
  if [[ -s "${pci}" ]]; then
    bdf_re="$(sed 's/\./\\./g' "${pci}" | paste -sd'|' -)"
  fi
  local hits=""
  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    dmesg_is_relevant "${line}" "${bdf_re}" || continue
    if dmesg_is_drop "${line}"; then
      hits+="${line}"$'\n'
    fi
  done < "${file}"
  if [[ -z "${hits}" ]]; then
    pass "${name}"
    return 0
  fi
  fail "${name}"
  printf '%s' "${hits}" | sed -n '1,20s/^/    /p'
  return 1
}

check_chips() {
  local before="$1" after="$2"
  local name="Tenstorrent chip count"
  local before_chips after_chips
  before_chips="$(cat "${before}/chips")"
  after_chips="$(cat "${after}/chips")"
  if [[ "${before_chips}" == "${after_chips}" ]]; then
    pass "${name} (${after_chips} in /dev/tenstorrent)"
    return 0
  fi
  fail "${name}"
  echo "    before ${before_chips}, after ${after_chips}"
  return 1
}

cmd_compare() {
  local before="${1:-}" after="${2:-}"
  [[ -n "${before}" && -n "${after}" && -d "${before}" && -d "${after}" ]] || usage
  local failed=0
  check_chips "${before}" "${after}" || failed=1
  check_identity "${before}" "${after}" || failed=1
  check_pci "${before}" "${after}" || failed=1
  check_raid_health "${before}" "${after}" || failed=1
  check_raid_members "${before}" "${after}" || failed=1
  check_failed_markers "${after}" || failed=1
  check_mounts "${before}" "${after}" || failed=1
  check_dmesg "${after}" "${before}/pci" || failed=1
  echo ""
  if [[ "${failed}" -ne 0 ]]; then
    echo "RESULT: FAIL"
    return 1
  fi
  echo "RESULT: PASS"
  return 0
}

write_fixture() {
  local dir="$1"
  shift
  mkdir -p "${dir}"
  : > "${dir}/identity"
  : > "${dir}/pci"
  : > "${dir}/raid"
  : > "${dir}/raid-members"
  : > "${dir}/mounts"
  : > "${dir}/dmesg-new"
  printf '1\n' > "${dir}/nvme-count"
  printf '32\n' > "${dir}/chips"
  local key value
  while [[ $# -ge 2 ]]; do
    key="$1"
    value="$2"
    shift 2
    printf '%s' "${value}" > "${dir}/${key}"
  done
}

assert_compare() {
  local expect="$1" before="$2" after="$3" label="$4"
  local rc=0
  set +e
  cmd_compare "${before}" "${after}" >/dev/null
  rc=$?
  set -e
  if [[ "${expect}" == pass && "${rc}" -ne 0 ]]; then
    echo "self-test FAIL: ${label} (expected PASS)" >&2
    cmd_compare "${before}" "${after}" >&2 || true
    return 1
  fi
  if [[ "${expect}" == fail && "${rc}" -eq 0 ]]; then
    echo "self-test FAIL: ${label} (expected FAIL)" >&2
    cmd_compare "${before}" "${after}" >&2 || true
    return 1
  fi
  echo "self-test ok: ${label}"
}

cmd_self_test() {
  local root
  root="$(mktemp -d)"
  # Expand the path now and clear the trap so it does not fire again when main returns.
  trap "rm -rf $(printf '%q' "${root}"); trap - RETURN" RETURN

  local parsed
  parsed="$(printf '%s\n' \
    'Personalities : [raid1] [raid10]' \
    'md1 : active raid10 nvme5n1[3] nvme4n1[2] nvme3n1[1] nvme2n1[0]' \
    '      3906764800 blocks super 1.2 512K chunks 2 near-copies [4/4] [UUUU]' \
    'md0 : active raid1 nvme1n1[1] nvme0n1[0]' \
    '      976630784 blocks super 1.2 [2/2] [UU]' \
    | parse_mdstat_text)"
  local expected=$'md0\traid1\t[2/2]\t[UU]\t0\nmd1\traid10\t[4/4]\t[UUUU]\t0'
  if [[ "${parsed}" != "${expected}" ]]; then
    echo "self-test FAIL: mdstat parser" >&2
    printf 'got:\n%s\n' "${parsed}" >&2
    return 1
  fi
  echo "self-test ok: mdstat parser"

  local degraded
  degraded="$(printf '%s\n' \
    'md1 : active raid10 nvme5n1[3](F) nvme4n1[2] nvme3n1[1] nvme2n1[0]' \
    '      100 blocks [4/3] [UUU_]' \
    | parse_mdstat_text)"
  [[ "${degraded}" == $'md1\traid10\t[4/3]\t[UUU_]\t1' ]] || {
    echo "self-test FAIL: degraded mdstat" >&2
    printf 'got:\n%s\n' "${degraded}" >&2
    return 1
  }
  echo "self-test ok: degraded mdstat"

  local ident=$'S1\tModel A\tnvme0n1\t100\n'
  local pci=$'0000:01:00.0\n'
  local raid=$'md0\traid1\t[2/2]\t[UU]\t0\n'
  local members=$'md0\tS1,S2\n'
  local mounts=$'rw\t/mnt/data\n'

  write_fixture "${root}/ok-before" identity "${ident}" pci "${pci}" raid "${raid}" raid-members "${members}" mounts "${mounts}"
  write_fixture "${root}/ok-after" identity "${ident}" pci "${pci}" raid "${raid}" raid-members "${members}" mounts "${mounts}"
  printf '%s\n' 'pci 0000:aa:00.0: link down' > "${root}/ok-after/dmesg-new"
  assert_compare pass "${root}/ok-before" "${root}/ok-after" "stable drives ignore non-NVMe dmesg"

  write_fixture "${root}/drop-after" identity "" pci "${pci}" raid "${raid}" raid-members "${members}" mounts "${mounts}"
  printf '0\n' > "${root}/drop-after/nvme-count"
  assert_compare fail "${root}/ok-before" "${root}/drop-after" "missing drive identity"

  write_fixture "${root}/bdf-after" identity "${ident}" pci $'0000:02:00.0\n' raid "${raid}" raid-members "${members}" mounts "${mounts}"
  assert_compare fail "${root}/ok-before" "${root}/bdf-after" "PCI address changed"

  local raid_bad=$'md1\traid10\t[4/3]\t[UUU_]\t1\n'
  write_fixture "${root}/raid-after" identity "${ident}" pci "${pci}" raid "${raid_bad}" raid-members "${members}" mounts "${mounts}"
  assert_compare fail "${root}/ok-before" "${root}/raid-after" "RAID degraded"

  write_fixture "${root}/ro-after" identity "${ident}" pci "${pci}" raid "${raid}" raid-members "${members}" mounts ""
  assert_compare fail "${root}/ok-before" "${root}/ro-after" "tracked mount disappeared"

  write_fixture "${root}/dmesg-after" identity "${ident}" pci "${pci}" raid "${raid}" raid-members "${members}" mounts "${mounts}"
  printf '%s\n' 'nvme nvme0: resetting controller' > "${root}/dmesg-after/dmesg-new"
  assert_compare fail "${root}/ok-before" "${root}/dmesg-after" "NVMe controller reset in dmesg"

  write_fixture "${root}/bdf-dmesg-after" identity "${ident}" pci "${pci}" raid "${raid}" raid-members "${members}" mounts "${mounts}"
  printf '%s\n' 'pcieport 0000:01:00.0: PCIe Bus Error: severity=Uncorrected' > "${root}/bdf-dmesg-after/dmesg-new"
  assert_compare fail "${root}/ok-before" "${root}/bdf-dmesg-after" "PCIe error on an NVMe BDF"

  echo "self-test RESULT: PASS"
}

main() {
  local cmd="${1:-}"
  shift || true
  case "${cmd}" in
    snapshot) cmd_snapshot "$@" ;;
    summary) cmd_summary "$@" ;;
    mark) cmd_mark "$@" ;;
    settle) cmd_settle "$@" ;;
    collect-dmesg) cmd_collect_dmesg "$@" ;;
    compare) cmd_compare "$@" ;;
    self-test) cmd_self_test "$@" ;;
    *) usage ;;
  esac
}

main "$@"
