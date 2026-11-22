#!/usr/bin/env bash
set -euo pipefail

if [[ ${1-} == '-h' || ${1-} == '--help' ]]; then
  printf 'Usage: %s [tag]\nDefault tag: 13. Set PLATFORM to linux/amd64 (default) or linux/arm64.\n' "${0##*/}"
  printf 'Requires: modules/*.zip and recam/{recam,librecam.so} — see README "准备".\n'
  printf 'Build: 构建系统资产镜像；首启自动安装 Magisk 模块与 Xposed 应用。\n'
  exit 0
fi

if [[ $# -gt 1 ]]; then
  printf 'Usage: %s [tag]\n' "${0##*/}" >&2
  exit 2
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

if ! compgen -G "$repo_dir/modules/*.zip" >/dev/null; then
  printf 'Error: no module zip in modules/ — download modules first (see README "准备").\n' >&2
  exit 1
fi
if [[ ! -f $repo_dir/recam/recam || ! -f $repo_dir/recam/librecam.so ]]; then
  printf 'Error: recam/recam and recam/librecam.so missing — download from ReCam releases (see README "准备").\n' >&2
  exit 1
fi

# ---------------------------------------------------------------- 构建
docker buildx build --platform "$platform" --tag "droid-kit:$tag" --load "$repo_dir"

printf '构建完成：droid-kit:%s（首启自动安装模块，同一轮启动生效，无需重启）。\n' "$tag"
