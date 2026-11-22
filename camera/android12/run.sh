#!/usr/bin/env bash
# Start a Redroid 12 container with the legacy V4L2 camera HAL bind-mounted in.
# No image rebuild is required; the base image stays untouched.
set -euo pipefail

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
android12_dir="$repo_dir"
vendor="$android12_dir/vendor"
files="$android12_dir/files"

BASE_IMAGE=${BASE_IMAGE:-redroid/redroid:12.0.0_64only-latest}
VIDEO_DEV=${VIDEO_DEV:-/dev/video10}
NAME=${NAME:-droid-kit-12-cam}
PORT=${PORT:-5555}
WIDTH=${WIDTH:-1080}
HEIGHT=${HEIGHT:-1920}
DPI=${DPI:-480}
HOST_IP=${HOST_IP:-127.0.0.1}

die() { echo "error: $*" >&2; exit 1; }
[[ -f "$vendor/lib64/hw/camera.v4l2.so" ]] || die "missing HAL: $vendor/lib64/hw/camera.v4l2.so (run ./build.sh)"
[[ -f "$vendor/bin/hw/android.hardware.camera.provider@2.4-service_64" ]] || die "missing provider (run ./build.sh)"
[[ -f "$vendor/etc/init/android.hardware.camera.provider@2.4-service_64.rc" ]] || die "missing provider rc (run ./build.sh)"
[[ -e "$VIDEO_DEV" ]] || die "$VIDEO_DEV not found; load v4l2loopback or pass a USB camera"

prop_dir="$vendor/prop"
mkdir -p "$prop_dir"
tmp_name="dk-cam-prop-$$"

echo "Preparing ro.hardware.camera=v4l2 property files from $BASE_IMAGE"
docker create --name "$tmp_name" "$BASE_IMAGE" >/dev/null
cleanup() { docker rm -f "$tmp_name" >/dev/null 2>&1 || true; }
trap cleanup EXIT

for spec in "vendor:/vendor/build.prop:vendor-build.prop" "system:/system/build.prop:system-build.prop"; do
  src=${spec%%:*}; rest=${spec#*:}; path=${rest%:*}; dst=${rest##*:}
  # src is kept for readability of the spec, but only path/dst are used.
  : "$src"
  if docker cp "$tmp_name:$path" "$prop_dir/$dst" >/dev/null 2>&1; then
    grep -q '^ro.hardware.camera=' "$prop_dir/$dst" || \
      echo 'ro.hardware.camera=v4l2' >> "$prop_dir/$dst"
    echo "  patched $path -> $prop_dir/$dst"
  else
    echo "  warning: $path not found in base image"
  fi
done
cleanup
trap - EXIT

mounts=(
  -v "$vendor/bin/hw/android.hardware.camera.provider@2.4-service_64:/vendor/bin/hw/android.hardware.camera.provider@2.4-service_64:ro"
  -v "$vendor/etc/init/android.hardware.camera.provider@2.4-service_64.rc:/vendor/etc/init/android.hardware.camera.provider@2.4-service_64.rc:ro"
  -v "$files/camera-ns-fix.rc:/vendor/etc/init/camera-ns-fix.rc:ro"
  -v "$files/manifest-camera.xml:/vendor/etc/vintf/manifest/manifest-camera.xml:ro"
)
# Mount the HAL and its provider/device impl libraries one file at a time. Do not
# mount all of /vendor/lib64: that would hide the base image's graphics/audio libs.
while IFS= read -r f; do
  [[ -n "$f" ]] || continue
  mounts+=(-v "$f:/vendor/lib64/$(basename "$f"):ro")
done < <(find "$vendor/lib64" -maxdepth 1 -type f -name '*.so' 2>/dev/null | sort)
while IFS= read -r f; do
  [[ -n "$f" ]] || continue
  mounts+=(-v "$f:/vendor/lib64/hw/$(basename "$f"):ro")
done < <(find "$vendor/lib64/hw" -maxdepth 1 -type f -name '*.so' 2>/dev/null | sort)
[[ -f "$prop_dir/vendor-build.prop" ]] && mounts+=(-v "$prop_dir/vendor-build.prop:/vendor/build.prop:ro")
[[ -f "$prop_dir/system-build.prop" ]] && mounts+=(-v "$prop_dir/system-build.prop:/system/build.prop:ro")

docker rm -f "$NAME" >/dev/null 2>&1 || true

echo "Starting $NAME ($BASE_IMAGE), $VIDEO_DEV -> /dev/video0"
docker run -itd --privileged \
  --name "$NAME" \
  --device "$VIDEO_DEV:/dev/video0" \
  "${mounts[@]}" \
  -p "$PORT:5555" \
  "$BASE_IMAGE" \
  "androidboot.redroid_width=$WIDTH" \
  "androidboot.redroid_height=$HEIGHT" \
  "androidboot.redroid_dpi=$DPI" >/dev/null

cat <<EOF

Started. Verify with:
  adb connect $HOST_IP:$PORT
  $repo_dir/../verify/verify-camera.sh

Logs:
  adb logcat -d | grep -iE 'camera|v4l2|linker'
EOF
