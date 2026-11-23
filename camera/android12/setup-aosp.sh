#!/usr/bin/env bash
# Sync an AOSP 12 tree for building the legacy V4L2 camera HAL/provider.
#
# This is intentionally separate from the Docker build: the AOSP tree is large
# and should live outside the repo. The default path is /app/data/aosp12.
set -euo pipefail

AOSP_DIR=${AOSP_DIR:-/app/data/aosp12}
AOSP_BRANCH=${AOSP_BRANCH:-android-12.0.0_r34}
AOSP_MIRROR=${AOSP_MIRROR:-https://android.googlesource.com/platform/manifest}
JOBS=${JOBS:-16}

command -v git >/dev/null || { echo "git is required" >&2; exit 1; }
command -v python3 >/dev/null || { echo "python3 is required" >&2; exit 1; }
command -v curl >/dev/null || { echo "curl is required" >&2; exit 1; }

mkdir -p "$AOSP_DIR"
cd "$AOSP_DIR"

if [[ ! -x repo ]]; then
  echo "Downloading repo tool..."
  curl -fsSL https://storage.googleapis.com/git-repo-downloads/repo -o repo
  chmod +x repo
fi

if [[ ! -d .repo ]]; then
  echo "Initializing AOSP $AOSP_BRANCH from $AOSP_MIRROR"
  ./repo init -u "$AOSP_MIRROR" -b "$AOSP_BRANCH" \
    --depth=1 --partial-clone --clone-filter=blob:limit=20M
else
  echo "Reusing existing repo at $AOSP_DIR"
fi

# Large projects not needed for the two camera modules.
mkdir -p .repo/local_manifests
cat > .repo/local_manifests/remove-heavy.xml <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<manifest>
  <remove-project name="device/amlogic/yukawa-kernel" />
  <remove-project name="device/google/barbet-kernel" />
  <remove-project name="device/google/bonito-kernel" />
  <remove-project name="device/google/coral-kernel" />
  <remove-project name="device/google/crosshatch-kernel" />
  <remove-project name="device/google/cuttlefish_prebuilts" />
  <remove-project name="device/google/redbull-kernel" />
  <remove-project name="device/google/sunfish-kernel" />
  <remove-project name="device/linaro/dragonboard-kernel" />
  <remove-project name="device/linaro/hikey-kernel" />
  <remove-project name="device/linaro/poplar-kernel" />
  <remove-project name="device/ti/beagle-x15-kernel" />
  <remove-project name="platform/cts" />
  <remove-project name="platform/external/noto-fonts" />
  <remove-project name="platform/external/openscreen" />
  <remove-project name="platform/packages/apps/TV" />
  <remove-project name="platform/packages/modules/ArtPrebuilt" />
  <remove-project name="platform/packages/modules/BootPrebuilt/5.4/arm64" />
  <remove-project name="platform/prebuilts/clang/host/darwin-x86" />
  <remove-project name="platform/prebuilts/qemu-kernel" />
  <remove-project name="platform/test/vts-testcase/kernel" />
  <remove-project name="platform/external/grpc-grpc" />
  <remove-project name="platform/external/grpc-grpc-java" />
  <remove-project name="platform/external/libabigail" />
  <remove-project name="platform/external/deqp" />
  <remove-project name="platform/external/autotest" />
  <remove-project name="platform/external/libtextclassifier" />
  <remove-project name="platform/external/linux-kselftest" />
  <remove-project name="platform/external/llvm" />
  <remove-project name="toolchain/llvm-project" />
</manifest>
XML

echo "Syncing (this downloads tens of GB; press Ctrl-C to stop)..."
./repo sync -c -j"$JOBS" --no-tags --no-clone-bundle --optimized-fetch

cat <<EOF

AOSP tree ready: $AOSP_DIR
Next:
  cd $(dirname "$0")
  ./build.sh

If the host cannot build AOSP 12, use the bundled Ubuntu 20.04 builder:
  docker build -t droid-kit-aosp12-builder -f Dockerfile.builder .
  BUILD_IN_DOCKER=1 ./build.sh

Note: mirrors.ustc.edu.cn rate-limits large syncs (HTTP 429). The default
mirror is android.googlesource.com. A local mirror can be selected with
AOSP_MIRROR=... if it supports the same manifest paths.

EOF
