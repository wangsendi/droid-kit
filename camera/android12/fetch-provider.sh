#!/usr/bin/env bash
# Fetch the Android 12 camera provider and its HIDL/impl libraries from the
# official AOSP x86_64 emulator system image and stage them in vendor/.
#
# The reDroid 12 image ships no camera provider at all, and the provider is a
# generic vendor HIDL service that is easier (and safer) to reuse than to
# rebuild.  AOSP 12 vendor binaries are ABI-compatible with reDroid 12.
#
# Usage:
#   ./fetch-provider.sh
#   SYSTEM_IMAGE_ZIP=/path/to/x86_64-31_r05.zip ./fetch-provider.sh
#   OUT=/tmp/stage ./fetch-provider.sh
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
OUT=${OUT:-$here/vendor}
ZIP=${SYSTEM_IMAGE_ZIP:-}
URL=${SYSTEM_IMAGE_URL:-https://dl.google.com/android/repository/sys-img/android/x86_64-31_r05.zip}
SHA1=${SYSTEM_IMAGE_SHA1:-58bff3cb182c79bbfe3980fe77b87b51b9f7ad71}

die() { echo "error: $*" >&2; exit 1; }

command -v unzip >/dev/null || die "unzip is required"
command -v parted >/dev/null || die "parted is required"
command -v debugfs >/dev/null || die "debugfs (e2fsprogs) is required"

work=$(mktemp -d)
mnt="$work/mnt"
cleanup() {
  mountpoint -q "$mnt" && umount "$mnt" 2>/dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT

if [[ -z "$ZIP" ]]; then
  echo "Downloading $URL"
  curl -fL --retry 3 -o "$work/sysimg.zip" "$URL"
  ZIP="$work/sysimg.zip"
fi
[[ -f "$ZIP" ]] || die "$ZIP not found"

if [[ "$(basename "$ZIP")" == "x86_64-31_r05.zip" ]]; then
  echo "$SHA1  $ZIP" | sha1sum -c -
fi

echo "Extracting vendor.img"
unzip -q -o "$ZIP" 'x86_64/vendor.img' -d "$work/img"
vendor_img="$work/img/x86_64/vendor.img"
[[ -f "$vendor_img" ]] || die "vendor.img not found in $ZIP"

# GPT + ext4 image: vendor.img is a disk image whose first partition is the
# vendor filesystem (2048s.., 204800s on the API 31 image).
read -r start end count < <(
  parted -s -m "$vendor_img" unit s print |
    awk -F: '$1 ~ /^[0-9]+$/ { gsub("s", "", $2); gsub("s", "", $4); print $2, $3, $4; exit }'
)
[[ -n "${count:-}" ]] || die "cannot parse partition table of $vendor_img"
echo "vendor partition: start=$start sectors, size=$count sectors"
dd if="$vendor_img" of="$work/vendor-part.img" bs=512 skip="$start" count="$count" status=none

mkdir -p "$mnt" "$OUT/bin/hw" "$OUT/etc/init" "$OUT/lib64/hw"
if ! mount -o loop,ro "$work/vendor-part.img" "$mnt" 2>/dev/null; then
  echo "loop mount failed, falling back to debugfs"
  extract() {
    local rel=$1 dest=$2
    debugfs -R "dump /$rel $dest" "$work/vendor-part.img" >/dev/null 2>&1 || true
  }
  extract bin/hw/android.hardware.camera.provider@2.4-service_64 \
    "$OUT/bin/hw/android.hardware.camera.provider@2.4-service_64"
  extract etc/init/android.hardware.camera.provider@2.4-service_64.rc \
    "$OUT/etc/init/android.hardware.camera.provider@2.4-service_64.rc"
  extract lib64/hw/android.hardware.camera.provider@2.4-impl.so \
    "$OUT/lib64/hw/android.hardware.camera.provider@2.4-impl.so"
  # Glob-equipped debugfs dump is awkward; enumerate with ls -p.
  for dir in lib64; do
    debugfs -R "ls -p /$dir" "$work/vendor-part.img" 2>/dev/null |
      awk -F/ '/^\/[0-9]+$/ { next } { print $6 }' |
      while read -r name; do
        case "$name" in
          android.hardware.camera.*.so|camera.device@*-impl.so|libtinyxml2.so)
            extract "$dir/$name" "$OUT/$dir/$name" ;;
        esac
      done
  done
else
  src="$mnt"
  install -m 0755 "$src/bin/hw/android.hardware.camera.provider@2.4-service_64" \
    "$OUT/bin/hw/android.hardware.camera.provider@2.4-service_64"
  install -m 0644 "$src/etc/init/android.hardware.camera.provider@2.4-service_64.rc" \
    "$OUT/etc/init/android.hardware.camera.provider@2.4-service_64.rc"
  install -m 0644 "$src/lib64/hw/android.hardware.camera.provider@2.4-impl.so" \
    "$OUT/lib64/hw/android.hardware.camera.provider@2.4-impl.so"
  for f in "$src"/lib64/android.hardware.camera.*.so \
           "$src"/lib64/camera.device@*-impl.so \
           "$src"/lib64/libtinyxml2.so; do
    [[ -e "$f" ]] && install -m 0644 "$f" "$OUT/lib64/$(basename "$f")"
  done
  umount "$mnt"
fi

[[ -f "$OUT/bin/hw/android.hardware.camera.provider@2.4-service_64" ]] || \
  die "provider binary was not extracted"
[[ -f "$OUT/lib64/hw/android.hardware.camera.provider@2.4-impl.so" ]] || \
  die "provider impl was not extracted"

echo "Staged provider artifacts in $OUT"
find "$OUT" -maxdepth 2 -type f | sort
