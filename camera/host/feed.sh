#!/usr/bin/env bash
# Feed a file, RTSP/MJPEG URL, or local camera into /dev/videoN.
#
# Examples:
#   ./feed.sh video.mp4
#   INPUT_FORMAT=mjpeg ./feed.sh http://192.168.1.20:8080/video
#   INPUT_FORMAT=v4l2 INPUT_DEVICE=/dev/video2 ./feed.sh
set -euo pipefail

VIDEO_NR=${VIDEO_NR:-10}
PIX_FMT=${PIX_FMT:-yuv420p}
SCALE=${SCALE:-1920:1080}
FPS=${FPS:-30}
LOOP=${LOOP:-1}
INPUT_FORMAT=${INPUT_FORMAT:-}
INPUT_DEVICE=${INPUT_DEVICE:-}

input=${1-}
device="/dev/video$VIDEO_NR"
[[ -e "$device" ]] || { echo "$device not found; run setup-v4l2loopback.sh" >&2; exit 1; }

args=(-hide_banner -loglevel warning -nostdin)
if [[ -n "$INPUT_DEVICE" ]]; then
  args+=(-f v4l2 -i "$INPUT_DEVICE")
else
  [[ -n "$input" ]] || { echo "missing input file/URL" >&2; exit 1; }
  args+=(-re)
  [[ "$LOOP" == "1" ]] && args+=(-stream_loop -1)
  [[ -n "$INPUT_FORMAT" ]] && args+=(-f "$INPUT_FORMAT")
  args+=(-i "$input")
fi

exec ffmpeg "${args[@]}" \
  -vf "scale=$SCALE,fps=$FPS" \
  -pix_fmt "$PIX_FMT" \
  -f v4l2 "$device"
