#!/usr/bin/env bash
set -euo pipefail

if [[ $# -gt 1 ]]; then
  printf 'Usage: %s [tag]\n' "${0##*/}" >&2
  exit 2
fi

if [[ ${1-} == '-h' || ${1-} == '--help' ]]; then
  printf 'Usage: %s [tag]\nDefault tag: 13. Set PLATFORM to linux/amd64 (default) or linux/arm64.\n' "${0##*/}"
  exit 0
fi

tag=${1-13}
if [[ ! $tag =~ ^[a-zA-Z0-9_][a-zA-Z0-9_.-]{0,127}$ ]]; then
  printf 'Invalid Docker image tag: %s\n' "$tag" >&2
  exit 2
fi

platform=${PLATFORM:-linux/amd64}
case "$platform" in
  linux/amd64 | linux/arm64) ;;
  *)
    printf 'Unsupported platform: %s (use linux/amd64 or linux/arm64)\n' "$platform" >&2
    exit 2
    ;;
esac

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
exec docker buildx build --platform "$platform" --tag "droid-kit:$tag" --load "$repo_dir"
