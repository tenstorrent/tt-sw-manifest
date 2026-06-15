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
  dnf install -y git python3-pip jq curl sudo ca-certificates procps-ng findutils which
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
echo "Artifacts copied to /workspace/dist:"
ls -1 /workspace/dist
