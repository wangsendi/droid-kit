#!/usr/bin/env bash
# Build the Android 12 legacy camera.v4l2 HAL module by hand (no Soong).
#
# The module is a plain libhardware camera3 HAL, so it only needs a small set of
# public/internal headers and can be cross compiled with the NDK clang.  It is
# linked against the shared libraries that already exist in the target
# (reDroid 12) system image, which are staged in $LIBDIR.
#
# The AOSP source tree is only used for the HAL sources and the platform
# headers; the NDK supplies a consistent bionic/libc++ sysroot because the
# partially synced AOSP tree has mixed bionic/libcxx versions.
#
# Usage (inside the build container):
#   AOSP=/aosp OUT=/camera/vendor bash build-v4l2.sh
set -euo pipefail

AOSP=${AOSP:-/aosp}
SRC=${SRC:-$AOSP/hardware/libhardware/modules/camera/3_4}
NDK=${NDK:-$AOSP/ndk/android-ndk-r23c}
CLANG=${CLANG:-$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/x86_64-linux-android31-clang++}
LIBDIR=${LIBDIR:-$AOSP/rd12libs}
OUT=${OUT:-/camera/vendor}
API=${API:-31}

mkdir -p "$OUT/lib64/hw"

SRCS=(
    "$AOSP/frameworks/av/camera/CameraMetadata.cpp"
    "$AOSP/frameworks/av/camera/VendorTagDescriptor.cpp"
    arc/cached_frame.cpp
    arc/exif_utils.cpp
    arc/frame_buffer.cpp
    arc/image_processor.cpp
    arc/jpeg_compressor.cpp
    camera.cpp
    capture_request.cpp
    format_metadata_factory.cpp
    metadata/boottime_state_delegate.cpp
    metadata/enum_converter.cpp
    metadata/metadata.cpp
    metadata/metadata_reader.cpp
    request_tracker.cpp
    static_properties.cpp
    stream_format.cpp
    v4l2_camera.cpp
    v4l2_camera_hal.cpp
    v4l2_metadata_factory.cpp
    v4l2_wrapper.cpp
)

INCS=(
    -I"$SRC"
    -I"$AOSP/system/media/camera/include"
    -I"$AOSP/system/media/private/camera/include"
    -I"$AOSP/frameworks/av/camera/include"
    -I"$AOSP/frameworks/av/camera"
    -I"$AOSP/frameworks/native/libs/binder/include"
    -I"$AOSP/frameworks/native/libs/ui/include"
    -I"$AOSP/frameworks/native/include"
    -I"$AOSP/system/core/libutils/include"
    -I"$AOSP/system/core/libcutils/include"
    -I"$AOSP/system/core/libsync/include"
    -I"$AOSP/system/core/libsystem/include"
    -I"$AOSP/system/core/base/include"
    -I"$AOSP/system/libbase/include"
    -I"$AOSP/system/logging/liblog/include"
    -I"$AOSP/hardware/libhardware/include"
    -I"$AOSP/external/libchrome"
    -I"$AOSP/external/libexif"
    -I"$AOSP/external/libyuv/files/include"
    -I"$AOSP/external/libjpeg-turbo"
)

LIBS=(
    -L"$LIBDIR"
    -lc++
    -lbase
    -lbinder
    -lcamera_metadata
    -lchrome
    -lcutils
    -lexif
    -lhardware
    -llog
    -lsync
    -lutils
    -lyuv
    -ljpeg
    -lc
    -lm
    -ldl
)

CFLAGS=(
    --target="x86_64-linux-android$API"
    -std=gnu++17
    -fPIC
    -O2
    -DHAVE_JPEG
    -DNDEBUG
    -D_LIBCPP_ABI_NAMESPACE=__1
    -D__ANDROID__
    -DANDROID
    -fno-short-enums
    -fvisibility=hidden
    -fno-exceptions
    -fno-rtti
    -Wno-deprecated-declarations
)

OBJDIR=$(mktemp -d)
trap 'rm -rf "$OBJDIR"' EXIT

echo "compiling camera.v4l2 (${#SRCS[@]} files)"
pids=()
for s in "${SRCS[@]}"; do
    obj="$OBJDIR/$(echo "$s" | tr '/' '_').o"
    if [[ "$s" = /* ]]; then src_path="$s"; else src_path="$SRC/$s"; fi
    "$CLANG" -std=gnu++17 "${CFLAGS[@]}" "${INCS[@]}" -c "$src_path" -o "$obj" &
    pids+=($!)
    if [ "${#pids[@]}" -ge 8 ]; then
        wait "${pids[0]}"
        pids=("${pids[@]:1}")
    fi
done
for p in "${pids[@]}"; do wait "$p"; done

echo "linking $OUT/lib64/hw/camera.v4l2.so"
"$CLANG" -std=gnu++17 --target="x86_64-linux-android$API" -fPIC -shared \
    -nostartfiles -nostdlib++ \
    -Wl,-soname,camera.v4l2.so -Wl,--allow-shlib-undefined \
    -o "$OUT/lib64/hw/camera.v4l2.so" "$OBJDIR"/*.o "${LIBS[@]}"

file "$OUT/lib64/hw/camera.v4l2.so"
readelf -d "$OUT/lib64/hw/camera.v4l2.so" | grep -E 'NEEDED|SONAME'
