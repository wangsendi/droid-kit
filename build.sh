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

# Magisk APK：在宿主机下载并校验，再作为构建上下文传入（避免构建阶段网络挂死）
magisk_url=https://github.com/ayasa520/Magisk/releases/download/v31.1/Magisk-v31.1.apk
magisk_md5=10304bbeddb6e1bbc7040fc7ec133178
magisk_apk="$repo_dir/docker/Magisk-v31.1.apk"
if [[ ! -f $magisk_apk ]]; then
  printf 'Downloading Magisk v31.1...\n'
  tmp_apk="${magisk_apk}.tmp"
  curl -fsSL --http1.1 --retry 8 --retry-all-errors --retry-delay 2 \
    --connect-timeout 20 --speed-limit 1024 --speed-time 30 \
    -o "$tmp_apk" "$magisk_url"
  mv "$tmp_apk" "$magisk_apk"
fi
echo "${magisk_md5}  ${magisk_apk}" | md5sum -c -

# ---------------------------------------------------------------- 构建
docker buildx build --platform "$platform" --tag "droid-kit:$tag" --load "$repo_dir"

printf '构建完成：droid-kit:%s（首启自动安装模块，同一轮启动生效，无需重启）。\n' "$tag"
