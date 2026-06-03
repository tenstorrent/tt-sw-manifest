#!/usr/bin/env bash
# Back-compat shim — use golden-metal-images.sh
# shellcheck source=golden-metal-images.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/golden-metal-images.sh"
normalize_metalium_image_tag() { normalize_metal_image_tag "$@"; }
