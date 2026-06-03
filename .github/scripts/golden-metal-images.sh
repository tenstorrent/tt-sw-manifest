#!/usr/bin/env bash
# GHCR image names for golden metal CI (tag from golden.json "metal-version").
set -euo pipefail

readonly GOLDEN_METALIUM_RELEASE_REPO="ghcr.io/tenstorrent/tt-metal/tt-metalium-ubuntu-22.04-release-amd64"
readonly GOLDEN_METAL_UPSTREAM_REPO="ghcr.io/tenstorrent/tt-metal/upstream-tests-bh"

# GHCR release tags use a leading v (e.g. v0.71.2). golden.json may store v0.71.2 or 0.71.2.
normalize_metal_image_tag() {
  local tag="${1:?}"
  case "${tag}" in
    latest-rc | latest)
      printf '%s\n' "${tag}"
      ;;
    v*)
      printf '%s\n' "${tag}"
      ;;
    *)
      printf 'v%s\n' "${tag}"
      ;;
  esac
}

# Single tt-metal pin in golden.json → both container image tags.
read_golden_metal_version() {
  local golden_json="${1:?}"
  jq -r '
    .["metal-version"]
    // .["metalium-image-tag"]
    // empty
  ' "${golden_json}"
}

metalium_release_image_ref() {
  local tag="$1"
  printf '%s:%s\n' "${GOLDEN_METALIUM_RELEASE_REPO}" "$(normalize_metal_image_tag "${tag}")"
}

metal_upstream_image_ref() {
  local tag="$1"
  printf '%s:%s\n' "${GOLDEN_METAL_UPSTREAM_REPO}" "$(normalize_metal_image_tag "${tag}")"
}

resolve_metalium_release_image() {
  local golden_json="${1:?}"
  metalium_release_image_ref "$(read_golden_metal_version "${golden_json}")"
}

resolve_metal_upstream_image() {
  local golden_json="${1:?}"
  metal_upstream_image_ref "$(read_golden_metal_version "${golden_json}")"
}
