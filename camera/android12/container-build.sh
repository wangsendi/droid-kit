#!/usr/bin/env bash
# Long-running AOSP 12 build executed inside a detached Ubuntu 20.04 container.
# The container is intentionally independent of the agent shell so it survives
# server restarts. Artifacts land in /camera/vendor (host: camera/android12/vendor).
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C
export JAVA_HOME=/usr/lib/jvm/java-11-openjdk-amd64

log=/camera/container-build.log
LUNCH_TARGET=${LUNCH_TARGET:-aosp_x86_64-eng}
exec >> "$log" 2>&1
echo "=== droid-kit AOSP12 camera build $(date -u +%FT%TZ) ==="

sed -i 's|http://archive.ubuntu.com/ubuntu|http://mirrors.ustc.edu.cn/ubuntu|g; s|http://security.ubuntu.com/ubuntu|http://mirrors.ustc.edu.cn/ubuntu|g' /etc/apt/sources.list

apt-get -o Dpkg::Use-Pty=0 update
# Upgrade libc6 alone first; doing it inside the large transaction deadlocks
# dpkg-deb on this overlayfs setup.
apt-get -o Dpkg::Use-Pty=0 install -y --no-install-recommends libc6
apt-get -o Dpkg::Use-Pty=0 install -y --no-install-recommends \
  openjdk-11-jdk \
  python3 python3-pip python-is-python3 \
  git curl ca-certificates \
  bc bison build-essential ccache flex g++-multilib gcc-multilib \
  gnupg gperf imagemagick lib32ncurses5-dev lib32readline-dev lib32z1-dev \
  libelf-dev liblz4-tool libncurses5 libncurses5-dev libsdl1.2-dev \
  libc6-dev-i386 x11proto-core-dev libx11-dev libgl1-mesa-dev fontconfig \
  libssl-dev libxml2 libxml2-utils lzop pngcrush rsync schedtool \
  squashfs-tools xsltproc zip zlib1g-dev \
  file unzip wget cpio

git config --global --add safe.directory /aosp
git config --global user.name 'droid-kit builder'
git config --global user.email 'builder@localhost'
git config --global url."https://android.googlesource.com/".insteadOf "https://mirrors.ustc.edu.cn/aosp/"

cd /aosp
echo "=== repo sync ==="
for attempt in 1 2 3; do
  if ./repo sync -c -j8 --no-tags --no-clone-bundle --optimized-fetch; then
    break
  fi
  echo "repo sync attempt $attempt failed; retrying in 10s"
  sleep 10
done || echo "repo sync reported errors; checking required projects"

[[ -f build/envsetup.sh ]] || { echo "FATAL: build/envsetup.sh missing after sync"; exit 1; }
[[ -d hardware/libhardware/modules/camera/3_4 ]] || {
  echo "camera.v4l2 source missing; retrying targeted sync"
  ./repo sync -c -j4 platform/hardware/libhardware || true
}
[[ -d hardware/interfaces/camera/provider/2.4/default ]] || {
  echo "camera provider source missing; retrying targeted sync"
  ./repo sync -c -j4 platform/hardware/interfaces || true
}
[[ -d prebuilts/jdk/jdk11 ]] || {
  echo "JDK 11 prebuilt missing; retrying targeted sync"
  ./repo sync -c -j4 platform/prebuilts/jdk/jdk11 || true
}
[[ -d hardware/libhardware/modules/camera/3_4 ]] || { echo "FATAL: camera.v4l2 source missing"; exit 1; }
[[ -d hardware/interfaces/camera/provider/2.4/default ]] || { echo "FATAL: provider source missing"; exit 1; }

echo "=== apply camera.v4l2 patches ==="
cd /aosp/hardware/libhardware
for p in /camera/patches/*.patch; do
  [[ -e "$p" ]] || continue
  if git apply -p3 --reverse --check "$p" >/dev/null 2>&1; then
    echo "already applied: $(basename "$p")"
  elif git apply -p3 --check "$p" >/dev/null 2>&1; then
    echo "applying: $(basename "$p")"
    git apply -p3 "$p"
  else
    echo "FATAL: cannot apply $p"
    exit 1
  fi
done

cd /aosp
echo "=== lunch ==="
set +u
source build/envsetup.sh
lunch "$LUNCH_TARGET"

export USE_CAMERA_V4L2_HAL=true
echo "=== build ==="
m -j"${JOBS:-16}" camera.v4l2 android.hardware.camera.provider@2.4-service_64 android.hardware.camera.provider@2.4-impl

product_dir=$(find /aosp/out/target/product -maxdepth 1 -mindepth 1 -type d | head -1)
[[ -n "$product_dir" ]] || { echo "FATAL: no product dir"; exit 1; }

hal=$(find "$product_dir" -type f -path '*/system/lib64/hw/camera.v4l2.so' | head -1)
provider=$(find "$product_dir" -type f -name 'android.hardware.camera.provider@2.4-service_64' | head -1)
rc=/aosp/hardware/interfaces/camera/provider/2.4/default/android.hardware.camera.provider@2.4-service_64.rc
[[ -n "$hal" ]] || { echo "FATAL: camera.v4l2.so not found"; exit 1; }
[[ -n "$provider" ]] || { echo "FATAL: provider _64 not found"; exit 1; }
[[ -f "$rc" ]] || { echo "FATAL: provider _64 rc not found"; exit 1; }

out=/camera/vendor
rm -rf "$out"
mkdir -p "$out/lib64/hw" "$out/lib64" "$out/bin/hw" "$out/etc/init"
install -m 0644 "$hal" "$out/lib64/hw/camera.v4l2.so"
install -m 0755 "$provider" "$out/bin/hw/android.hardware.camera.provider@2.4-service_64"
install -m 0644 "$rc" "$out/etc/init/android.hardware.camera.provider@2.4-service_64.rc"

copy_camera_libs() {
  local dir=$1 dest=$2 f base
  [[ -d "$dir" ]] || return 0
  for f in "$dir"/*.so; do
    [[ -e "$f" ]] || continue
    base=$(basename "$f")
    case "$base" in
      android.hardware.camera* | camera.device@* | libtinyxml2.so | libexif.so | libchrome.so | libjpeg.so | libcamera_client.so | libcamera_metadata.so | libbase.so | libui.so | libnativewindow.so | libsync.so | libyuv.so)
        install -m 0644 "$f" "$dest/$base"
        ;;
    esac
  done
}
copy_camera_libs "$product_dir/vendor/lib64" "$out/lib64"
copy_camera_libs "$product_dir/system/lib64" "$out/lib64"
copy_camera_libs "$product_dir/vendor/lib64/hw" "$out/lib64/hw"
copy_camera_libs "$product_dir/system/lib64/hw" "$out/lib64/hw"

cat > "$out/BUILD-INFO.txt" <<EOF
built_at=$(date -u +%FT%TZ)
aosp_dir=/aosp
product_dir=$product_dir
hal=$hal
provider=$provider
EOF

echo "=== artifacts ==="
file "$out/lib64/hw/camera.v4l2.so" "$out/bin/hw/android.hardware.camera.provider@2.4-service_64"
readelf -d "$out/lib64/hw/camera.v4l2.so" | grep NEEDED || true
echo "=== done $(date -u +%FT%TZ) ==="
