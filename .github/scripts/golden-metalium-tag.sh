#!/usr/bin/env bash
# GHCR tags for tt-metalium-ubuntu-22.04-release-amd64 use a leading v (e.g. v0.71.2).
# golden.json may store v0.71.2 or 0.71.2; latest-rc is passed through unchanged.
normalize_metalium_image_tag() {
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
