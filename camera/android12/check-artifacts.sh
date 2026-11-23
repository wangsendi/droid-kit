#!/usr/bin/env bash
# Sanity-check staged Android 12 camera artifacts before running Docker.
set -euo pipefail

dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
out="$dir/vendor"

hal="$out/lib64/hw/camera.v4l2.so"
gralloc="$out/lib64/hw/gralloc.v4l2.so"
provider="$out/bin/hw/android.hardware.camera.provider@2.4-service_64"
rc="$out/etc/init/android.hardware.camera.provider@2.4-service_64.rc"

impl="$out/lib64/hw/android.hardware.camera.provider@2.4-impl.so"
device_impl=$(find "$out/lib64" -maxdepth 2 -type f -name 'camera.device@3.4-impl.so' | head -1)

for f in "$hal" "$gralloc" "$provider" "$rc" "$impl" "$device_impl"; do
  [[ -n "$f" && -e "$f" ]] || { echo "missing: $f" >&2; exit 1; }
  ls -l "$f"
done

file "$hal" | grep -q 'ELF 64-bit' || { echo "$hal is not 64-bit" >&2; exit 1; }
file "$gralloc" | grep -q 'ELF 64-bit' || { echo "$gralloc is not 64-bit" >&2; exit 1; }
file "$provider" | grep -q 'ELF 64-bit' || { echo "$provider is not 64-bit" >&2; exit 1; }
file "$provider" | grep -q 'x86-64' || { echo "$provider is not x86-64" >&2; exit 1; }
file "$impl" | grep -q 'ELF 64-bit' || { echo "$impl is not 64-bit" >&2; exit 1; }
file "$device_impl" | grep -q 'ELF 64-bit' || { echo "$device_impl is not 64-bit" >&2; exit 1; }

echo "--- HAL NEEDED ---"
readelf -d "$hal" | grep NEEDED || true
echo "--- provider NEEDED ---"
readelf -d "$provider" | grep NEEDED || true
echo "--- provider impl NEEDED ---"
readelf -d "$impl" | grep NEEDED || true
echo "--- staged libs ---"
find "$out/lib64" -maxdepth 2 -type f -name '*.so' -printf '%P\n' | sort
