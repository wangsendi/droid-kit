#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./build.sh [tag]                     Build Android 13 droid-kit image (default tag: 13)
  ./build.sh --android12-camera [tag]  Build Android 12 camera image (default tag: 12-camera)

Environment:
  PLATFORM=linux/amd64|linux/arm64    Build platform (Android 12 camera is amd64 only)
  BASE_IMAGE=<image>                  Override Android 12 base image
  AOSP_DIR=<path>                     AOSP 12 tree for camera/android12/build.sh
  BUILD_IN_DOCKER=1                   Build AOSP 12 HAL/provider in Ubuntu 20.04 builder
EOF
}

mode=13
case "${1-}" in
  -h | --help)
    usage
    exit 0
    ;;
  --android12-camera | --camera12)
    mode=12
    shift
    ;;
  --*)
    printf 'Unknown option: %s\n' "$1" >&2
    usage >&2
    exit 2
    ;;
esac

if [[ $# -gt 1 ]]; then
  usage >&2
  exit 2
fi

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
platform=${PLATFORM:-linux/amd64}
case "$platform" in
  linux/amd64 | linux/arm64) ;;
  *)
    printf 'Unsupported platform: %s (use linux/amd64 or linux/arm64)\n' "$platform" >&2
    exit 2
    ;;
esac

if [[ $mode == 12 ]]; then
  tag=${1:-12-camera}
  if [[ ! $tag =~ ^[a-zA-Z0-9_][a-zA-Z0-9_.-]{0,127}$ ]]; then
    printf 'Invalid Docker image tag: %s\n' "$tag" >&2
    exit 2
  fi
  if [[ $platform != linux/amd64 ]]; then
    printf 'Android 12 camera variant currently supports linux/amd64 only\n' >&2
    exit 2
  fi
  if [[ ! -f $repo_dir/Dockerfile.android12-camera ]]; then
    printf 'Missing Dockerfile.android12-camera\n' >&2
    exit 1
  fi
  "$repo_dir/camera/android12/build.sh"
  docker buildx build --platform "$platform" \
    --file "$repo_dir/Dockerfile.android12-camera" \
    --build-arg "BASE_IMAGE=${BASE_IMAGE:-redroid/redroid:12.0.0_64only-latest}" \
    --tag "droid-kit:$tag" --load "$repo_dir"
  printf '构建完成：droid-kit:%s（Android 12 + camera.v4l2，需要 /dev/video* 与 v4l2loopback）\n' "$tag"
  exit 0
fi

tag=${1:-13}
if [[ ! $tag =~ ^[a-zA-Z0-9_][a-zA-Z0-9_.-]{0,127}$ ]]; then
  printf 'Invalid Docker image tag: %s\n' "$tag" >&2
  exit 2
fi

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
