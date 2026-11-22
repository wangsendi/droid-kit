#!/usr/bin/env bash
# Create a host-side v4l2loopback device for Redroid.
set -euo pipefail

VIDEO_NR=${VIDEO_NR:-10}
CARD_LABEL=${CARD_LABEL:-Camera}
if [[ $(id -u) -eq 0 ]]; then SUDO=; else SUDO=sudo; fi

if ! lsmod | grep -qw v4l2loopback; then
  echo "Loading v4l2loopback (video$VIDEO_NR, label=$CARD_LABEL)..."
  $SUDO modprobe v4l2loopback \
    devices=1 \
    video_nr="$VIDEO_NR" \
    card_label="$CARD_LABEL" \
    exclusive_caps=1 \
    max_width=1920 max_height=1080 max_fps=30
fi

$SUDO chmod 666 "/dev/video$VIDEO_NR"

if command -v v4l2-ctl >/dev/null; then
  v4l2-ctl -d "/dev/video$VIDEO_NR" --list-formats-ext || true
fi

cat <<EOF

Device ready: /dev/video$VIDEO_NR
Feed it with:
  ./feed.sh /path/to/video.mp4
Or a live source:
  INPUT_FORMAT=mjpeg ./feed.sh http://PHONE_IP:8080/video

If modprobe fails:
  sudo apt install "linux-headers-\$(uname -r)" v4l2loopback-dkms v4l2loopback-utils
EOF
