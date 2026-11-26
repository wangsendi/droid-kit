#!/usr/bin/env bash
# Feed a Nova-Persona-Stream live session into a v4l2loopback device.
#
# Nova exposes a same-host HTTP WebM endpoint (VP8, optional Opus):
#   GET /api/stream                         -> phase / active_group_id / session_id
#   GET /api/stream/preview.webm?group_id=..&session_id=..
#
# This script polls the session, decodes the WebM with ffmpeg, scales/pads it
# to a camera-friendly YUYV frame and writes it to /dev/videoN. It reconnects
# when the session ends or the HTTP stream hits EOF.
#
# IMPORTANT:
#   * Nova's HTTP preview only accepts 127.0.0.1/localhost/::1. Run this where
#     127.0.0.1:8100 is reachable (same host or a sidecar sharing Nova's network
#     namespace). Cross-host: use `ssh -L 8100:127.0.0.1:8100 nova-host` first.
#   * Feed the loopback device before starting the Android container (the legacy
#     HAL has no hotplug). Keep this script running.
#   * Nova allows 4 preview connections per session. Two camera feeds plus
#     reconnects count against it; keep POLL >= 2s.
#
# Usage:
#   VIDEO_NR=10 ./feed-nova.sh                  # back camera
#   VIDEO_NR=11 ./feed-nova.sh                  # front camera
#   NOVA_BASE=http://127.0.0.1:8100 VIDEO_NR=10 ./feed-nova.sh
#   DRY_RUN=1 ./feed-nova.sh                    # print the ffmpeg command only
set -euo pipefail

NOVA_BASE=${NOVA_BASE:-http://127.0.0.1:8100}
VIDEO_NR=${VIDEO_NR:-10}
OUT_W=${OUT_W:-1280}
OUT_H=${OUT_H:-720}
FPS=${FPS:-30}
PIX_FMT=${PIX_FMT:-yuyv422}
POLL=${POLL:-2}
CURL=${CURL:-curl}
FFMPEG=${FFMPEG:-ffmpeg}
DRY_RUN=${DRY_RUN:-0}
DEV="/dev/video$VIDEO_NR"

if [[ "$DRY_RUN" != "1" ]]; then
    [[ -e "$DEV" ]] || { echo "error: $DEV not found (load v4l2loopback first)" >&2; exit 1; }
fi

json_field() {
    # json_field <json> <field> [default]
    python3 - "$1" "$2" "${3-}" <<'PY'
import json, sys
try:
    data = json.loads(sys.argv[1])
except Exception:
    print(sys.argv[3] if len(sys.argv) > 3 else "")
    raise SystemExit(0)
value = data
for part in sys.argv[2].split("."):
    if isinstance(value, dict):
        value = value.get(part)
    else:
        value = None
        break
print("" if value is None else value)
PY
}

urlencode() {
    python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"
}

last_session=""
while true; do
    status=$($CURL -fsS --max-time 5 "$NOVA_BASE/api/stream" 2>/dev/null || true)
    if [[ -z "$status" ]]; then
        sleep "$POLL"
        continue
    fi

    phase=$(json_field "$status" phase)
    gid=$(json_field "$status" active_group_id)
    sid=$(json_field "$status" session_id)
    width=$(json_field "$status" config.width "$OUT_W")
    height=$(json_field "$status" config.height "$OUT_H")
    fps=$(json_field "$status" config.fps "$FPS")

    if [[ "$phase" != "running" && "$phase" != "stopping" ]] || \
       [[ -z "$gid" || -z "$sid" ]]; then
        sleep "$POLL"
        continue
    fi

    url="$NOVA_BASE/api/stream/preview.webm?group_id=$(urlencode "$gid")&session_id=$(urlencode "$sid")"

    # Nova's live output is portrait (e.g. 1080x1920). Rotate it into the
    # landscape frame the camera HAL expects, then scale/pad to OUT_W x OUT_H.
    vf="scale=$OUT_W:$OUT_H:force_original_aspect_ratio=decrease"
    if [[ "$width" -lt "$height" ]]; then
        vf="transpose=1,$vf"
    fi
    vf="$vf,pad=$OUT_W:$OUT_H:(ow-iw)/2:(oh-ih)/2"

    cmd=("$FFMPEG" -nostdin -hide_banner -loglevel warning \
        -fflags nobuffer -flags low_delay \
        -i "$url" -an -vf "$vf" -r "$fps" -pix_fmt "$PIX_FMT")

    if [[ "$DRY_RUN" == "1" ]]; then
        printf '%q ' "${cmd[@]}"; echo "-f v4l2 $DEV"
        sleep 1
        last_session=$sid
        continue
    fi

    if [[ "$sid" != "$last_session" ]]; then
        echo "$(date '+%F %T') nova session $sid (${width}x${height}@${fps}) -> $DEV"
        last_session=$sid
    fi

    # ffmpeg exits on session stop/EOF/HTTP 409; re-poll and reconnect.
    "${cmd[@]}" -f v4l2 "$DEV" || true
    sleep "$POLL"
done
