#!/usr/bin/env bash
# Verify that Android sees the camera and that the browser-facing metadata is sane.
set -euo pipefail

HOST_IP=${HOST_IP:-127.0.0.1}
ADB=${ADB:-adb}
PORT=${PORT:-5555}
TARGET=${TARGET:-$HOST_IP:$PORT}
SERIAL=${SERIAL:-$TARGET}

"$ADB" connect "$TARGET" >/dev/null 2>&1 || true
adb_cmd=("$ADB" -s "$SERIAL")

echo "=== props ==="
"${adb_cmd[@]}" shell 'getprop ro.build.version.release; getprop ro.hardware.camera; getprop ro.hardware'

echo "=== video node ==="
"${adb_cmd[@]}" shell 'ls -l /dev/video* 2>&1'

echo "=== camera provider ==="
"${adb_cmd[@]}" shell 'lshal | grep -i camera || true'

echo "=== camera service ==="
"${adb_cmd[@]}" shell 'dumpsys media.camera 2>/dev/null | head -30'

echo "=== recent camera/linker logs ==="
"${adb_cmd[@]}" shell 'logcat -d 2>/dev/null | grep -iE "camera|v4l2|linker" | tail -60' || true

cat <<'EOF'

Browser check (Chrome/WebView):
  navigator.mediaDevices.enumerateDevices().then(console.log)
  navigator.mediaDevices.getUserMedia({video:true}).then(s => {
    const t = s.getVideoTracks()[0];
    console.log(t.label, t.getCapabilities(), t.getSettings());
  })
EOF
