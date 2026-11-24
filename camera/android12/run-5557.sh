#!/usr/bin/env bash
# Start a second reDroid 12 camera container with TWO V4L2 devices.
#
#   host /dev/video10 -> /dev/video0   (back camera, id 0)
#   host /dev/video11 -> /dev/video1   (front camera, id 1)
#
# Container: droid-kit-12-cam2, adb port 5557. The existing 5556 container
# (droid-kit-12-cam) is never stopped, removed or reconfigured: this script
# only manages its own NAME and PORT.
#
# Env (defaults in parentheses):
#   BASE_IMAGE  (redroid/redroid:12.0.0_64only-latest)
#   NAME        (droid-kit-12-cam2)
#   PORT        (5557)
#   VIDEO_DEV   (/dev/video10)  first host device  -> /dev/video0
#   VIDEO_DEV2  (/dev/video11)  second host device -> /dev/video1
#   WIDTH / HEIGHT / DPI        (1080 / 1920 / 480)
#
# ./run.sh is owned by another change. If it understands VIDEO_DEV2 (or
# /dev/video1), this script delegates to it; otherwise it performs the same
# docker create + docker cp sequence itself, adding the second --device.
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
run_sh="$script_dir/run.sh"
vendor="$script_dir/vendor"
files="$script_dir/files"

BASE_IMAGE=${BASE_IMAGE:-redroid/redroid:12.0.0_64only-latest}
NAME=${NAME:-droid-kit-12-cam2}
PORT=${PORT:-5557}
VIDEO_DEV=${VIDEO_DEV:-/dev/video10}
VIDEO_DEV2=${VIDEO_DEV2:-/dev/video11}
WIDTH=${WIDTH:-1080}
HEIGHT=${HEIGHT:-1920}
DPI=${DPI:-480}
HOST_IP=${HOST_IP:-127.0.0.1}

# The single-camera 5556 setup. Never remove or reuse it.
OTHER_NAME=${OTHER_NAME:-droid-kit-12-cam}

die() { echo "error: $*" >&2; exit 1; }

[[ "$NAME" != "$OTHER_NAME" ]] || \
  die "refusing to manage $OTHER_NAME; that container belongs to the 5556 setup"
[[ -x "$run_sh" ]] || die "missing $run_sh"
[[ -e "$VIDEO_DEV" ]] || \
  die "$VIDEO_DEV not found; start the back-camera v4l2loopback feed first"
[[ -e "$VIDEO_DEV2" ]] || \
  die "$VIDEO_DEV2 not found; start the front-camera v4l2loopback feed first"

print_next_steps() {
  cat <<EOF

Started $NAME on port $PORT:
  $VIDEO_DEV  -> /dev/video0 (back, id 0)
  $VIDEO_DEV2 -> /dev/video1 (front, id 1)

Verify:
  adb connect $HOST_IP:$PORT
  PORT=$PORT $script_dir/../verify/verify-camera.sh
  PORT=$PORT $script_dir/../verify/verify-metadata.sh
  # WebView check: see $script_dir/../verify/camtest/README.md

Logs:
  docker logs -f $NAME
EOF
}

# Fallback path: mirror run.sh (docker create + docker cp, no bind mounts) but
# map both video devices. Kept in sync with run.sh's file list by copying every
# staged vendor library instead of naming them individually.
create_here() {
  "$script_dir/check-artifacts.sh" >/dev/null

  docker rm -f "$NAME" >/dev/null 2>&1 || true
  echo "Creating $NAME ($BASE_IMAGE), $VIDEO_DEV -> /dev/video0, $VIDEO_DEV2 -> /dev/video1"
  docker create --name "$NAME" --privileged \
    --device "$VIDEO_DEV:/dev/video0" \
    --device "$VIDEO_DEV2:/dev/video1" \
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

  # HAL + provider/device impl libraries.
  for f in "$vendor"/lib64/hw/*.so; do
    [[ -e "$f" ]] || continue
    copy "$f" "/vendor/lib64/hw/$(basename "$f")"
  done
  for f in "$vendor"/lib64/*.so; do
    [[ -e "$f" ]] || continue
    copy "$f" "/vendor/lib64/$(basename "$f")"
  done

  # provider, rc, linker workaround, VINTF fragment, media profiles.
  copy "$vendor/bin/hw/android.hardware.camera.provider@2.4-service_64" \
    "/vendor/bin/hw/android.hardware.camera.provider@2.4-service_64"
  copy "$vendor/etc/init/android.hardware.camera.provider@2.4-service_64.rc" \
    "/vendor/etc/init/android.hardware.camera.provider@2.4-service_64.rc"
  copy "$files/camera-ns-fix.rc" "/vendor/etc/init/camera-ns-fix.rc"
  copy "$files/manifest-camera.xml" "/vendor/etc/vintf/manifest/manifest-camera.xml"
  copy "$files/media_profiles_V1_0.xml" "/system/etc/media_profiles_V1_0.xml"

  # ro.hardware.camera / ro.hardware.gralloc must be set before boot.
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
  set_prop ro.hardware.gralloc v4l2
  docker cp "$prop_tmp" "$NAME:/vendor/build.prop"
  rm -f "$prop_tmp"

  docker start "$NAME" >/dev/null
  trap - EXIT
}

has_second_device() {
  local mapped
  mapped=$(docker inspect \
    --format '{{range .HostConfig.Devices}}{{.PathInContainer}} {{end}}' \
    "$NAME" 2>/dev/null || true)
  [[ " $mapped " == *" /dev/video1 "* ]]
}

# Prefer run.sh when the owner of that file has taught it about the second
# device; it also knows about any new files the upgraded HAL needs.
if grep -qE 'VIDEO_DEV2|/dev/video1' "$run_sh"; then
  echo "run.sh mentions VIDEO_DEV2; delegating to it (NAME=$NAME PORT=$PORT)"
  if NAME="$NAME" PORT="$PORT" HOST_IP="$HOST_IP" \
      VIDEO_DEV="$VIDEO_DEV" VIDEO_DEV2="$VIDEO_DEV2" \
      BASE_IMAGE="$BASE_IMAGE" WIDTH="$WIDTH" HEIGHT="$HEIGHT" DPI="$DPI" \
      "$run_sh"; then
    if has_second_device; then
      print_next_steps
      exit 0
    fi
    echo "warning: $NAME has no /dev/video1 mapping; recreating with the built-in fallback" >&2
    docker rm -f "$NAME" >/dev/null 2>&1 || true
  else
    echo "warning: run.sh failed; recreating with the built-in fallback" >&2
    docker rm -f "$NAME" >/dev/null 2>&1 || true
  fi
fi

create_here
has_second_device || die "$NAME does not map /dev/video1 (unexpected)"
print_next_steps
