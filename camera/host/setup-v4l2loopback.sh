#!/usr/bin/env bash
# Create the host-side v4l2loopback devices used by Redroid:
#   /dev/video10 -> container /dev/video0 -> camera 0 (back)
#   /dev/video11 -> container /dev/video1 -> camera 1 (front)
#
# A producer (feed.sh) must be writing to a device before the container starts:
# exclusive_caps=1 means a loopback node only advertises V4L2_CAP_VIDEO_CAPTURE
# while something is streaming into it, and the legacy HAL has no hotplug.
set -euo pipefail

VIDEO_NR=${VIDEO_NR:-10}
VIDEO_NR2=${VIDEO_NR2:-11}
CARD_LABEL=${CARD_LABEL:-Camera}
CARD_LABEL2=${CARD_LABEL2:-CameraFront}
if [[ $(id -u) -eq 0 ]]; then SUDO=; else SUDO=sudo; fi

if [[ ! -d /sys/module/v4l2loopback ]]; then
  echo "Loading v4l2loopback (video_nr=$VIDEO_NR,$VIDEO_NR2," \
       "labels=$CARD_LABEL,$CARD_LABEL2)..."
  $SUDO modprobe v4l2loopback \
    devices=2 \
    video_nr="$VIDEO_NR,$VIDEO_NR2" \
    card_label="$CARD_LABEL,$CARD_LABEL2" \
    exclusive_caps=1 \
    max_width=1920 max_height=1080 max_fps=30
fi

# udev often does not run in containers, so /dev nodes can be missing even
# though the kernel created the devices. Recreate them from sysfs if needed.
ensure_node() {
  local nr=$1
  local node="/dev/video$1"
  local sys="/sys/class/video4linux/video$1/dev"
  if [[ ! -e "$node" ]]; then
    if [[ ! -r "$sys" ]]; then
      echo "missing $node and $sys does not exist" >&2
      return 1
    fi
    local major_minor
    major_minor=$(cat "$sys")
    echo "Creating $node (char ${major_minor%%:*}:${major_minor##*:})"
    $SUDO mknod "$node" c "${major_minor%%:*}" "${major_minor##*:}" || return 1
  fi
  $SUDO chmod 666 "$node" || return 1
}

failed=0
for nr in "$VIDEO_NR" "$VIDEO_NR2"; do
  ensure_node "$nr" || failed=1
done
if [[ $failed -ne 0 || ! -c "/dev/video$VIDEO_NR" || ! -c "/dev/video$VIDEO_NR2" ]]; then
  cat >&2 <<'EOF'
Both loopback devices are required. If v4l2loopback was already loaded with a
different configuration (for example a single device), reload it and retry:
  sudo modprobe -r v4l2loopback
  ./setup-v4l2loopback.sh
EOF
  exit 1
fi

# With exclusive_caps=1 the format list is empty until a producer starts, so a
# failure here is not fatal; the devices are checked above.
if command -v v4l2-ctl >/dev/null; then
  for nr in "$VIDEO_NR" "$VIDEO_NR2"; do
    echo
    echo "/dev/video$nr:"
    v4l2-ctl -d "/dev/video$nr" --list-formats-ext || true
  done
fi

cat <<EOF

Devices ready:
  /dev/video$VIDEO_NR  ($CARD_LABEL) -> container /dev/video0, camera 0 (back)
  /dev/video$VIDEO_NR2 ($CARD_LABEL2) -> container /dev/video1, camera 1 (front)

Feed BOTH before starting the Redroid container (the legacy HAL has no hotplug),
otherwise the unfed camera is absent from the HAL's enumeration:
  ./feed.sh /path/to/back.mp4                  # VIDEO_NR=$VIDEO_NR (default)
  VIDEO_NR=$VIDEO_NR2 ./feed.sh /path/to/front.mp4
Live sources:
  INPUT_FORMAT=mjpeg ./feed.sh http://PHONE_IP:8080/video
  VIDEO_NR=$VIDEO_NR2 INPUT_FORMAT=mjpeg ./feed.sh http://PHONE_IP:8081/video

If modprobe fails:
  sudo apt install "linux-headers-\$(uname -r)" v4l2loopback-dkms v4l2loopback-utils
EOF
