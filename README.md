# ttis-golden-versions

Golden version pins (`golden.json`) and CI that mirrors a **customer install**: run [tt-installer](https://github.com/tenstorrent/tt-installer) once, then exercise the stack on real hardware.

## What CI does

| Job | Runners | Flow |
|-----|---------|------|
| **No hardware** | `ubuntu-latest` (container) | `golden-install.sh` → `verify-golden-versions.sh` |
| **Hardware** | `tt-ubuntu-2204-n150-stable`, `tt-ubuntu-2204-p150b-stable` | `golden-install-hw.sh` → version verify → `tt-smi -r` ×10 → **tt-metalium workload** |

Hardware jobs do **not** re-run the installer or pull separate `upstream-tests-bh` images. Metal coverage follows [tt-installer `test-hosted-n150.yml`](https://github.com/tenstorrent/tt-installer/blob/main/.github/workflows/test-hosted-n150.yml): a small `ttnn` smoke test inside the **tt-metalium release** container the installer already pulled.

## Pins (`golden.json`)

| Field | Role |
|-------|------|
| `installer`, `kmd`, `smi`, `flash`, `firmware` | Passed to tt-installer |
| `metalium-image-tag` | GHCR tag for `tt-metalium-ubuntu-22.04-release-amd64` (must include leading **`v`**, e.g. `v0.71.2`; bare `0.71.2` is not on the registry) |

## Runner labels vs instance names

GitHub Actions sets `GITHUB_RUNNER_NAME` to the **ephemeral** name (e.g. `tt-ubuntu-2204-n150-stable-d7m7v-runner-9swlw`). The workflow matrix label (`tt-ubuntu-2204-n150-stable`) is passed as `GOLDEN_RUNNER_LABEL` for board lookup in `.github/golden-metal-boards.json`. tt-installer avoids this by using a single `runs-on:` label with no board JSON.

## Logs

Self-hosted runners may print `sudo: unable to resolve host ubuntu` — harmless; see comment in `.github/workflows/golden-hw.yml`.
