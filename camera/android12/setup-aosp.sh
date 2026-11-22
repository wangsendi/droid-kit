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

# noto-fonts is large and not needed for the camera HAL/provider build.
mkdir -p .repo/local_manifests
cat > .repo/local_manifests/remove-noto.xml <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<manifest>
  <remove-project name="platform/external/noto-fonts" />
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
