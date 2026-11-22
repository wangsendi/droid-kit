#!/usr/bin/env bash
# Build the legacy V4L2 camera HAL and the HIDL 2.4 camera provider from an
# AOSP 12 tree, then stage them in camera/android12/vendor/ for docker cp injection.
#
# The AOSP tree is expected at $AOSP_DIR (default /app/data/aosp12). Create it
# with ./setup-aosp.sh first.
set -euo pipefail

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
AOSP_DIR=${AOSP_DIR:-/app/data/aosp12}
JOBS=${JOBS:-16}
BUILD_IN_DOCKER=${BUILD_IN_DOCKER:-1}
BUILDER_IMAGE=${BUILDER_IMAGE:-droid-kit-aosp12-builder}
LUNCH_TARGET=${LUNCH_TARGET:-aosp_x86_64-eng}
HOST_AOSP_DIR=${HOST_AOSP_DIR:-$AOSP_DIR}
HOST_CAMERA_DIR=${HOST_CAMERA_DIR:-$repo_dir}
OUT="$repo_dir/vendor"

die() { echo "error: $*" >&2; exit 1; }

if [[ ${USE_PREBUILT:-0} == 1 ]]; then
  src="$repo_dir/prebuilt"
  [[ -f "$src/lib64/hw/camera.v4l2.so" ]] || die "missing $src/lib64/hw/camera.v4l2.so"
  [[ -f "$src/bin/hw/android.hardware.camera.provider@2.4-service_64" ]] || die "missing $src/bin/hw/android.hardware.camera.provider@2.4-service_64"
  [[ -f "$src/etc/init/android.hardware.camera.provider@2.4-service_64.rc" ]] || die "missing $src/etc/init/android.hardware.camera.provider@2.4-service_64.rc"
  rm -rf "$OUT"
  mkdir -p "$OUT"
  cp -a "$src/." "$OUT/"
  echo "Staged prebuilt artifacts from $src"
  exit 0
fi

if [[ ${FORCE_BUILD:-0} != 1 \
   && -s "$OUT/lib64/hw/camera.v4l2.so" \
   && -x "$OUT/bin/hw/android.hardware.camera.provider@2.4-service_64" \
   && -f "$OUT/etc/init/android.hardware.camera.provider@2.4-service_64.rc" \
   && -f "$OUT/lib64/hw/android.hardware.camera.provider@2.4-impl.so" ]] \
   && file "$OUT/lib64/hw/camera.v4l2.so" | grep -q 'ELF 64-bit' \
   && file "$OUT/bin/hw/android.hardware.camera.provider@2.4-service_64" | grep -q 'ELF 64-bit'; then
  echo "Reusing staged artifacts in $OUT (set FORCE_BUILD=1 to rebuild)"
  exit 0
fi

[[ -d "$AOSP_DIR/build" ]] || die "AOSP tree not found at $AOSP_DIR; run ./setup-aosp.sh"

patch_one() {
  local patch=$1
  if git -C "$AOSP_DIR/hardware/libhardware" apply -p3 --reverse --check "$patch" >/dev/null 2>&1; then
    echo "already applied: $(basename "$patch")"
  elif git -C "$AOSP_DIR/hardware/libhardware" apply -p3 --check "$patch" >/dev/null 2>&1; then
    echo "applying: $(basename "$patch")"
    git -C "$AOSP_DIR/hardware/libhardware" apply -p3 "$patch"
  else
    die "cannot apply $patch (tree has local changes or version mismatch)"
  fi
}

for p in "$repo_dir"/patches/*.patch; do
  [[ -e "$p" ]] || continue
  patch_one "$p"
done

# --- build -------------------------------------------------------------------
build_cmd=$(cat <<'EOS'
set -euo pipefail
cd /aosp
set +u
source build/envsetup.sh
lunch "$LUNCH_TARGET"
export USE_CAMERA_V4L2_HAL=true
m -j"$JOBS" camera.v4l2 android.hardware.camera.provider@2.4-service_64 android.hardware.camera.provider@2.4-impl
EOS
)

if [[ "$BUILD_IN_DOCKER" == "1" ]]; then
  command -v docker >/dev/null || die "docker is required for BUILD_IN_DOCKER=1"
  if ! docker image inspect "$BUILDER_IMAGE" >/dev/null 2>&1; then
    echo "Building AOSP 12 builder image (one-time, several minutes)..."
    docker build -t "$BUILDER_IMAGE" -f "$repo_dir/Dockerfile.builder" "$repo_dir"
  fi
  docker run --rm \
    -v "$HOST_AOSP_DIR:/aosp" \
    -v "$HOST_CAMERA_DIR:/repo" \
    -e LUNCH_TARGET="$LUNCH_TARGET" \
    -e JOBS="$JOBS" \
    -w /aosp \
    "$BUILDER_IMAGE" bash -lc "$build_cmd"
else
  cd "$AOSP_DIR"
  set +u
  source build/envsetup.sh
  lunch "$LUNCH_TARGET"
  export USE_CAMERA_V4L2_HAL=true
  m -j"$JOBS" camera.v4l2 android.hardware.camera.provider@2.4-service_64 android.hardware.camera.provider@2.4-impl
fi

# --- collect artifacts -------------------------------------------------------
product_dir=$(find "$AOSP_DIR/out/target/product" -maxdepth 1 -mindepth 1 -type d | head -1)
[[ -n "$product_dir" ]] || die "no build product directory under $AOSP_DIR/out/target/product"

hal=$(find "$product_dir" -type f -path '*/system/lib64/hw/camera.v4l2.so' | head -1)
[[ -n "$hal" ]] || hal=$(find "$product_dir" -type f -name 'camera.v4l2.so' | head -1)
provider=$(find "$product_dir" -type f -name 'android.hardware.camera.provider@2.4-service_64' | head -1)
[[ -n "$hal" ]] || die "camera.v4l2.so not found in $product_dir"
[[ -n "$provider" ]] || die "android.hardware.camera.provider@2.4-service_64 not found in $product_dir"

file "$hal" | grep -q 'ELF 64-bit' || die "$hal is not 64-bit"
file "$provider" | grep -q 'ELF 64-bit' || die "$provider is not 64-bit"

rm -rf "$OUT"
mkdir -p "$OUT/lib64/hw" "$OUT/bin/hw" "$OUT/etc/init"
install -m 0644 "$hal" "$OUT/lib64/hw/camera.v4l2.so"
install -m 0755 "$provider" "$OUT/bin/hw/android.hardware.camera.provider@2.4-service_64"

# The provider service dlopens its HIDL implementation and the camera.device
# impl libraries. Those are not present in the official Redroid image, so stage
# them next to the HAL. libchrome/libexif are needed by camera.v4l2 on some
# AOSP 12 builds.
copy_camera_libs() {
  local dir=$1 dest=$2 f base
  [[ -d "$dir" ]] || return 0
  for f in "$dir"/*.so; do
    [[ -e "$f" ]] || continue
    base=$(basename "$f")
    case "$base" in
      android.hardware.camera* | camera.device@* | libtinyxml2.so | libexif.so | libchrome.so | libjpeg.so | libcamera_client.so | libcamera_metadata.so | libbase.so | libui.so | libnativewindow.so | libsync.so | libyuv.so)
        install -m 0644 "$f" "$dest/$base"
        ;;
    esac
  done
}
copy_camera_libs "$product_dir/vendor/lib64" "$OUT/lib64"
copy_camera_libs "$product_dir/system/lib64" "$OUT/lib64"
copy_camera_libs "$product_dir/vendor/lib64/hw" "$OUT/lib64/hw"
copy_camera_libs "$product_dir/system/lib64/hw" "$OUT/lib64/hw"

rc_src="$AOSP_DIR/hardware/interfaces/camera/provider/2.4/default/android.hardware.camera.provider@2.4-service_64.rc"
if [[ -f "$rc_src" ]]; then
  install -m 0644 "$rc_src" "$OUT/etc/init/android.hardware.camera.provider@2.4-service_64.rc"
else
  echo "warning: provider rc not found at $rc_src; run.sh will fail unless you supply it" >&2
fi

cat > "$OUT/BUILD-INFO.txt" <<EOF
built_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
aosp_dir=$AOSP_DIR
lunch_target=$LUNCH_TARGET
hal=$hal
provider=$provider
EOF

echo
echo "Staged artifacts:"
file "$OUT/lib64/hw/camera.v4l2.so" "$OUT/bin/hw/android.hardware.camera.provider@2.4-service_64"
readelf -d "$OUT/lib64/hw/camera.v4l2.so" | grep NEEDED || true
echo
echo "Next: ./run.sh"
