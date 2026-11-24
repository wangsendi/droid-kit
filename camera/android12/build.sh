#!/usr/bin/env bash
# Build the Android 12 legacy camera stack and stage it in
# camera/android12/vendor/ for `docker cp` injection by run.sh.
#
# What is built from source (AOSP 12 hardware/libhardware):
#   * camera.v4l2.so      - legacy camera3 HAL, patched for multi-stream and
#                           MMAP streaming (v4l2loopback only supports MMAP)
#   * gralloc.v4l2.so     - software gralloc with YUV_420_888 allocation and
#                           (*lock_ycbcr) support (reDroid's stock gralloc is
#                           RGB-only, which breaks Camera2 ImageReaders)
#
# What is staged from the AOSP 12 x86_64 emulator vendor image (see docs):
#   * android.hardware.camera.provider@2.4-service_64
#   * android.hardware.camera.provider@2.4-impl.so, camera.device@*-impl.so
#   * the camera HIDL interface libraries
# Those binaries are already in vendor/ and are not rebuilt here.
#
# Prerequisites (see README/docs):
#   * AOSP 12 tree at $AOSP_DIR with hardware/libhardware
#   * NDK r23c unpacked at $AOSP_DIR/ndk/android-ndk-r23c
#   * reDroid 12 shared libraries staged at $AOSP_DIR/rd12libs
#
# Usage:
#   ./build.sh                  # build with the dk-build2 container if running
#   BUILDER= ./build.sh         # build on the host (needs the same paths)
#   USE_PREBUILT=1 ./build.sh   # stage camera/android12/prebuilt/ instead
set -euo pipefail

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
AOSP_DIR=${AOSP_DIR:-/app/data/aosp12}
OUT="$repo_dir/vendor"
BUILDER=${BUILDER-dk-build2}

die() { echo "error: $*" >&2; exit 1; }

if [[ ${USE_PREBUILT:-0} == 1 ]]; then
  src="$repo_dir/prebuilt"
  [[ -f "$src/lib64/hw/camera.v4l2.so" ]] || die "missing $src/lib64/hw/camera.v4l2.so"
  [[ -f "$src/lib64/hw/gralloc.v4l2.so" ]] || die "missing $src/lib64/hw/gralloc.v4l2.so"
  [[ -f "$src/bin/hw/android.hardware.camera.provider@2.4-service_64" ]] || die "missing provider"
  rm -rf "$OUT"
  mkdir -p "$OUT"
  cp -a "$src/." "$OUT/"
  echo "Staged prebuilt artifacts from $src"
  exit 0
fi

[[ -d "$AOSP_DIR/hardware/libhardware/modules/camera/3_4" ]] || \
  die "AOSP tree not found at $AOSP_DIR (run ./setup-aosp.sh)"
[[ -d "$AOSP_DIR/ndk/android-ndk-r23c" ]] || \
  die "NDK r23c not found at $AOSP_DIR/ndk/android-ndk-r23c"
[[ -d "$AOSP_DIR/rd12libs" ]] || \
  die "reDroid 12 libraries not found at $AOSP_DIR/rd12libs"

patch_one() {
  local root=$1 patch=$2
  if git -C "$root" apply -p3 --reverse --check "$patch" >/dev/null 2>&1; then
    echo "already applied: $(basename "$patch")"
  elif git -C "$root" apply -p3 --check "$patch" >/dev/null 2>&1; then
    echo "applying: $(basename "$patch")"
    git -C "$root" apply -p3 "$patch"
  else
    die "cannot apply $patch (tree has local changes or version mismatch)"
  fi
}

for p in "$repo_dir"/patches/*.patch; do
  [[ -e "$p" ]] || continue
  patch_one "$AOSP_DIR/hardware/libhardware" "$p"
done

build() {
  local script=$1
  if [[ -n "$BUILDER" ]] && \
     docker inspect -f '{{.State.Running}}' "$BUILDER" 2>/dev/null | grep -qx true; then
    docker exec "$BUILDER" bash "/camera/$script"
  else
    AOSP="$AOSP_DIR" OUT="$OUT" bash "$repo_dir/$script"
  fi
}

build build-v4l2.sh
build build-gralloc.sh

# The provider/impl binaries live in vendor/ but are gitignored (they are
# extracted from the emulator image, not built from local sources).
[[ -x "$OUT/bin/hw/android.hardware.camera.provider@2.4-service_64" ]] || \
  die "provider binary missing in $OUT; see docs/CAMERA-ANDROID12.md section 2"
[[ -f "$OUT/lib64/hw/android.hardware.camera.provider@2.4-impl.so" ]] || \
  die "provider impl missing in $OUT; see docs/CAMERA-ANDROID12.md section 2"

cat > "$OUT/BUILD-INFO.txt" <<EOF
built_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
aosp_dir=$AOSP_DIR
builder=${BUILDER:-host}
EOF

echo
"$repo_dir/check-artifacts.sh"
echo
echo "Next: HOST_IP=... ./run.sh"
