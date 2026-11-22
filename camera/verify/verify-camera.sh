#!/usr/bin/env bash
# Verify that Android sees the camera and that the browser-facing metadata is sane.
set -euo pipefail

ADB=${ADB:-adb}
HOST_IP=${HOST_IP:-127.0.0.1}
PORT=${PORT:-5555}
TARGET=${TARGET:-$HOST_IP:$PORT}
SERIAL=${SERIAL:-$TARGET}

"$ADB" connect "$TARGET" >/dev/null 2>&1 || true
if ! timeout 60 "$ADB" -s "$SERIAL" wait-for-device >/dev/null 2>&1; then
  echo "error: $SERIAL not ready (adb connect failed or boot incomplete)" >&2
  exit 1
fi

# adbd is up before sys.boot_completed; the linker fix/provider restart runs at
# boot_completed, so wait for it before reading camera state.
boot=
for _ in $(seq 1 60); do
  boot=$("$ADB" -s "$SERIAL" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')
  [[ "$boot" == "1" ]] && break
  sleep 2
done
if [[ "$boot" != "1" ]]; then
  echo "error: sys.boot_completed never became 1" >&2
  exit 1
fi

echo "=== props ==="
"$ADB" -s "$SERIAL" shell 'getprop ro.build.version.release; getprop ro.hardware.camera; getprop ro.hardware'

echo "=== video node ==="
"$ADB" -s "$SERIAL" shell 'ls -l /dev/video* 2>&1'

echo "=== camera provider ==="
provider_out=
for _ in $(seq 1 15); do
  provider_out=$("$ADB" -s "$SERIAL" shell 'lshal | grep -i camera || true')
  grep -qE 'ICameraProvider/(legacy|external)/0' <<<"$provider_out" && break
  sleep 2
done
echo "$provider_out"

echo "=== camera service ==="
camera_out=
for _ in $(seq 1 15); do
  camera_out=$("$ADB" -s "$SERIAL" shell 'dumpsys media.camera 2>/dev/null | head -30')
  grep -q 'Number of camera devices: [1-9]' <<<"$camera_out" && break
  sleep 2
done
echo "$camera_out"

echo "=== recent camera/linker logs ==="
"$ADB" -s "$SERIAL" shell 'logcat -d 2>/dev/null | grep -iE "camera|v4l2|linker" | tail -60' || true

status=0
if ! grep -q 'Number of camera devices: [1-9]' <<<"$camera_out"; then
  echo "FAIL: no camera device enumerated" >&2
  status=1
fi
if ! grep -qE 'ICameraProvider/(legacy|external)/0' <<<"$provider_out"; then
  echo "FAIL: camera provider not registered (expected legacy/0)" >&2
  status=1
fi
if ! "$ADB" -s "$SERIAL" shell 'getprop ro.hardware.camera' | grep -qx 'v4l2'; then
  echo "FAIL: ro.hardware.camera is not v4l2" >&2
  status=1
fi

cat <<'EOF'

Browser check (Chrome/WebView):
  navigator.mediaDevices.enumerateDevices().then(console.log)
  navigator.mediaDevices.getUserMedia({video:true}).then(s => {
    const t = s.getVideoTracks()[0];
    console.log(t.label, t.getCapabilities(), t.getSettings());
  })
EOF

exit "$status"
