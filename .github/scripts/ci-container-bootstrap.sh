#!/usr/bin/env bash
# Bootstrap a fresh distro container for the no-hardware .ttis build+test, then
# run it as an unprivileged user (tt-installer refuses to run as root).
#
# Runs as root from /workspace (the mounted repo). Copies the compiled .ttis to
# /workspace/dist for the workflow to upload.
set -euxo pipefail

if command -v apt-get >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y git python3-pip jq curl sudo ca-certificates
else
  # libatomic: tt-smi's tt_umd extension dlopens libatomic.so.1 at runtime, which
  # the minimal fedora image lacks (present on Ubuntu/Debian). See note below —
  # the durable fix is to add it to tt-installer's Fedora dependency list.
  dnf install -y git python3-pip jq curl sudo ca-certificates procps-ng findutils which libatomic
fi

# tenstorrent-tools runs `systemctl` in its post-install scriptlet (to enable the
# hugepages unit). Containers have no systemd: on dnf/Fedora a non-zero scriptlet
# aborts the whole rpm transaction, while apt/dpkg only logs and continues. We
# install this package solely so --export-schema can resolve its version, so drop
# in a no-op shim where systemctl is absent to keep the scriptlet (and the install)
# happy. Harmless on images that already ship a real systemctl.
if ! command -v systemctl >/dev/null 2>&1; then
  printf '#!/bin/sh\nexit 0\n' > /usr/bin/systemctl
  chmod 0755 /usr/bin/systemctl
fi

id testuser >/dev/null 2>&1 || useradd -m -s /bin/bash testuser
echo "testuser ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/testuser

rm -rf /home/testuser/workspace
cp -r /workspace /home/testuser/workspace
chown -R testuser:testuser /home/testuser/workspace

# Forward the installer-source env into testuser's login shell (su - resets env).
# Values expand here (root); \$HOME expands in testuser's shell.
su - testuser -c "
  set -euo pipefail
  export INSTALLER_REPO='${INSTALLER_REPO:-}'
  export INSTALLER_TAG='${INSTALLER_TAG:-}'
  export SKIP_INSTALLER_VERSION_CHECK='${SKIP_INSTALLER_VERSION_CHECK:-}'
  export GOLDEN_JSON=\"\$HOME/workspace/golden.json\"
  cd \"\$HOME/workspace\"
  bash .github/scripts/build-and-test-ttis.sh
"

mkdir -p /workspace/dist
cp /home/testuser/workspace/golden/*.ttis /workspace/dist/
# ttis_export writes via mktemp (mode 0600) + mv, so the exported .ttis is
# owner-only. The upload-artifact step runs as the host runner user, not root, and
# can't read a root-owned 0600 file. Make them world-readable (the .ttis is not
# secret) so the upload succeeds.
chmod 0644 /workspace/dist/*.ttis
echo "Artifacts copied to /workspace/dist:"
ls -1l /workspace/dist
