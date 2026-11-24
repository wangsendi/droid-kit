#!/usr/bin/env bash
# Build droid-kit: Android 12 (reDroid) + legacy camera.v4l2 + anti-detection
# modules (Magisk/Zygisk, LSPosed, Shamiko, PlayIntegrityFix, HMA, ...).
#
# Usage:
#   ./build.sh [tag]        # default tag: 12-camera
#
# Environment:
#   PLATFORM=linux/amd64                (Android 12 image is amd64 only)
#   BASE_IMAGE=<image>                  override the reDroid 12 base
#   BUILDER=<docker container>          camera HAL build container (optional)
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./build.sh [tag]

Builds droid-kit:<tag> (default 12-camera): Android 12 reDroid + camera.v4l2
HAL/provider + Magisk/Xposed modules preloaded from modules/ and recam/.

Environment:
  PLATFORM=linux/amd64      build platform (amd64 only)
  BASE_IMAGE=<image>        override Android 12 base image
  BUILDER=<container>       container used by camera/android12/build.sh
EOF
}

case "${1-}" in
  -h | --help) usage; exit 0 ;;
  --*) printf 'Unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
esac
if [[ $# -gt 1 ]]; then usage >&2; exit 2; fi

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
tag=${1:-12-camera}
platform=${PLATFORM:-linux/amd64}

if [[ ! $tag =~ ^[a-zA-Z0-9_][a-zA-Z0-9_.-]{0,127}$ ]]; then
  printf 'Invalid Docker image tag: %s\n' "$tag" >&2
  exit 2
fi
if [[ $platform != linux/amd64 ]]; then
  printf 'Android 12 camera image supports linux/amd64 only\n' >&2
  exit 2
fi

# ---------------------------------------------------------------- assets
if ! compgen -G "$repo_dir/modules/*.zip" >/dev/null; then
  printf 'Error: no module zip in modules/ — download modules first (see README "准备").\n' >&2
  exit 1
fi
if [[ ! -f $repo_dir/recam/recam || ! -f $repo_dir/recam/librecam.so ]]; then
  printf 'Error: recam/recam and recam/librecam.so missing — download ReCam (see README "准备").\n' >&2
  exit 1
fi

# Magisk APK is downloaded/verified on the host, then passed via build context.
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

# ---------------------------------------------------------------- camera
"$repo_dir/camera/android12/build.sh"
"$repo_dir/camera/android12/check-artifacts.sh"

# ---------------------------------------------------------------- image
docker buildx build --platform "$platform" --load \
  --file "$repo_dir/Dockerfile.android12-camera" \
  --build-arg "BASE_IMAGE=${BASE_IMAGE:-redroid/redroid:12.0.0_64only-latest}" \
  --tag "droid-kit:$tag" "$repo_dir"

printf '构建完成：droid-kit:%s（Android 12 + camera.v4l2 + Magisk/Xposed 模块）\n' "$tag"
