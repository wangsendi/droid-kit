#!/usr/bin/env bash
# Start a Redroid 12 container with the legacy V4L2 camera HAL injected.
#
# No image rebuild is required, but this does NOT use `-v` for new files:
# Docker creates a directory when a bind-mount target does not exist, which
# silently breaks HAL/rc/VINTF injection. Instead we `docker create` the
# container, `docker cp` the files into it, and then `docker start`.
set -euo pipefail

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
vendor="$repo_dir/vendor"
files="$repo_dir/files"

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
[[ -f "$vendor/lib64/hw/gralloc.v4l2.so" ]] || die "missing gralloc: $vendor/lib64/hw/gralloc.v4l2.so (run ./build.sh)"
[[ -f "$vendor/bin/hw/android.hardware.camera.provider@2.4-service_64" ]] || die "missing provider (run ./build.sh)"
[[ -f "$vendor/etc/init/android.hardware.camera.provider@2.4-service_64.rc" ]] || die "missing provider rc (run ./build.sh)"
[[ -e "$VIDEO_DEV" ]] || die "$VIDEO_DEV not found; load v4l2loopback and start the feed first"
"$repo_dir/check-artifacts.sh"

docker rm -f "$NAME" >/dev/null 2>&1 || true
echo "Creating $NAME ($BASE_IMAGE), $VIDEO_DEV -> /dev/video0"
docker create --name "$NAME" --privileged \
  --device "$VIDEO_DEV:/dev/video0" \
  -p "$PORT:5555" \
  "$BASE_IMAGE" \
  "androidboot.redroid_width=$WIDTH" \
  "androidboot.redroid_height=$HEIGHT" \
  "androidboot.redroid_dpi=$DPI" >/dev/null

cleanup() { docker rm -f "$NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT

copy() {
  local src=$1 dst=$2
  [[ -e "$src" ]] || die "missing source: $src"
  docker cp "$src" "$NAME:$dst"
}

# HAL + provider/device impl libraries
for f in "$vendor"/lib64/hw/*.so; do
  [[ -e "$f" ]] || continue
  copy "$f" "/vendor/lib64/hw/$(basename "$f")"
done
for f in "$vendor"/lib64/*.so; do
  [[ -e "$f" ]] || continue
  copy "$f" "/vendor/lib64/$(basename "$f")"
done

# provider, rc, linker workaround, VINTF fragment
copy "$vendor/bin/hw/android.hardware.camera.provider@2.4-service_64" \
  "/vendor/bin/hw/android.hardware.camera.provider@2.4-service_64"
copy "$vendor/etc/init/android.hardware.camera.provider@2.4-service_64.rc" \
  "/vendor/etc/init/android.hardware.camera.provider@2.4-service_64.rc"
copy "$files/camera-ns-fix.rc" "/vendor/etc/init/camera-ns-fix.rc"
copy "$files/manifest-camera.xml" "/vendor/etc/vintf/manifest/manifest-camera.xml"
# MediaProfiles is empty in the reDroid image.  The camera1 shim
# (Camera2Client) derives the preview/video size list from the video encoder
# caps in this XML and refuses to open the camera when it is missing.
copy "$files/media_profiles_V1_0.xml" "/system/etc/media_profiles_V1_0.xml"

# ro.hardware.camera must be set from /vendor/build.prop before boot.
# /vendor/build.prop is a regular file in redroid 12 and is loaded after
# /system/build.prop, so it is the safest place to set the property.
prop_tmp=$(mktemp)
docker cp "$NAME:/vendor/build.prop" "$prop_tmp" >/dev/null 2>&1 || \
  die "cannot read /vendor/build.prop from $BASE_IMAGE"
set_prop() {
  local key=$1 value=$2
  if grep -q "^$key=" "$prop_tmp"; then
    sed -i "s|^$key=.*|$key=$value|" "$prop_tmp"
  else
    echo "$key=$value" >> "$prop_tmp"
  fi
}
set_prop ro.hardware.camera v4l2
# reDroid's ashmem gralloc only allocates RGB; the camera HAL and Camera2
# ImageReaders also need YUV_420_888 buffers.
set_prop ro.hardware.gralloc v4l2
docker cp "$prop_tmp" "$NAME:/vendor/build.prop"
rm -f "$prop_tmp"

docker start "$NAME" >/dev/null
trap - EXIT

cat <<EOF

Started. Verify with:
  adb connect $HOST_IP:$PORT
  $repo_dir/../verify/verify-camera.sh

Logs:
  adb logcat -d | grep -iE 'camera|v4l2|linker'
EOF
