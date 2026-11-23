#!/usr/bin/env bash
# Build a YUV-capable copy of the AOSP software gralloc HAL.
#
# reDroid ships the legacy ashmem gralloc, which only allocates RGB buffers.
# Camera2 clients (Chrome/WebView, Camera2) ask the allocator for
# HAL_PIXEL_FORMAT_YCbCr_420_888 buffers, so allocation fails and getUserMedia
# never receives frames.  This module keeps the RGB behaviour and adds planar
# YUV 4:2:0 / 4:2:2 (plus NV21) buffers and (*lock_ycbcr)().
#
# It is installed as gralloc.v4l2.so and selected with
#   ro.hardware.gralloc=v4l2
#
# Usage (inside the build container):
#   AOSP=/aosp OUT=/camera/vendor bash build-gralloc.sh
set -euo pipefail

AOSP=${AOSP:-/aosp}
SRC=${SRC:-$AOSP/hardware/libhardware/modules/gralloc}
NDK=${NDK:-$AOSP/ndk/android-ndk-r23c}
CLANG=${CLANG:-$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/x86_64-linux-android31-clang++}
LIBDIR=${LIBDIR:-$AOSP/rd12libs}
OUT=${OUT:-/camera/vendor}
API=${API:-31}

mkdir -p "$OUT/lib64/hw"

INCS=(
    -I"$SRC"
    -I"$AOSP/hardware/libhardware/include"
    -I"$AOSP/system/core/libcutils/include"
    -I"$AOSP/system/logging/liblog/include"
    -I"$AOSP/system/core/libsystem/include"
)

"$CLANG" --target="x86_64-linux-android$API" \
    -std=gnu++17 -fPIC -O2 -DNDEBUG -DLOG_TAG=\"gralloc\" \
    -Wno-missing-field-initializers \
    "${INCS[@]}" \
    -shared -nostartfiles -nostdlib++ \
    -Wl,-soname,gralloc.v4l2.so -Wl,--allow-shlib-undefined \
    -o "$OUT/lib64/hw/gralloc.v4l2.so" \
    "$SRC/gralloc.cpp" "$SRC/framebuffer.cpp" "$SRC/mapper.cpp" \
    -L"$LIBDIR" -lcutils -llog -lc -lm -ldl

file "$OUT/lib64/hw/gralloc.v4l2.so"
readelf -d "$OUT/lib64/hw/gralloc.v4l2.so" | grep -E 'NEEDED|SONAME'
