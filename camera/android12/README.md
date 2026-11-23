# Android 12 legacy V4L2 camera (reDroid)

Working implementation of `docs/安卓12方案.md`, verified end-to-end in
Chrome/WebView `getUserMedia` on `redroid/redroid:12.0.0_64only-latest`.

```text
Host v4l2loopback (/dev/video10, YUYV 1280x720, ffmpeg)
        │
        ▼
Redroid 12 container
  ├── /vendor/lib64/hw/camera.v4l2.so                  (built here)
  ├── /vendor/lib64/hw/gralloc.v4l2.so                 (built here, YUV)
  ├── /vendor/bin/hw/android.hardware.camera.provider@2.4-service_64
  ├── /vendor/lib64/android.hardware.camera.*.so
  ├── /vendor/lib64/hw/android.hardware.camera.provider@2.4-impl.so
  ├── /vendor/lib64/camera.device@*-impl.so
  ├── /vendor/etc/init/android.hardware.camera.provider@2.4-service_64.rc
  ├── /vendor/etc/vintf/manifest/manifest-camera.xml
  ├── /system/etc/media_profiles_V1_0.xml
  └── /vendor/build.prop: ro.hardware.camera=v4l2, ro.hardware.gralloc=v4l2
        │
        ▼
cameraserver (Camera2) → WebView getUserMedia
```

## Pieces and where they come from

| Piece | Source |
|---|---|
| `camera.v4l2.so` | AOSP 12 `hardware/libhardware/modules/camera/3_4`, patched and cross-compiled with NDK r23c (`build-v4l2.sh`) |
| `gralloc.v4l2.so` | AOSP 12 `hardware/libhardware/modules/gralloc`, patched for YUV_420_888 + `lock_ycbcr` (`build-gralloc.sh`) |
| provider 2.4 + impl libs | AOSP 12 x86_64 emulator image `x86_64-31_r05.zip` (vendor partition), fetched with `fetch-provider.sh` into `vendor/` |
| `media_profiles_V1_0.xml` | generated from the AOSP goldfish config, shipped in `files/` |

The official reDroid 12 image has no camera provider, no `camera.v4l2.so`, and
its software gralloc only allocates RGB buffers. All three gaps are filled by
this directory.

## Build

```bash
./fetch-provider.sh        # one-time: stage provider binaries from the emulator image
./build.sh                 # uses the running dk-build2 container if present
BUILDER= ./build.sh        # or build on the host
USE_PREBUILT=1 ./build.sh  # stage camera/android12/prebuilt/ instead
```

Prerequisites (see `docs/CAMERA-ANDROID12.md`):

- AOSP 12 tree at `$AOSP_DIR` (default `/app/data/aosp12`)
- NDK r23c at `$AOSP_DIR/ndk/android-ndk-r23c`
- reDroid 12 system libraries at `$AOSP_DIR/rd12libs`

`build.sh` applies `patches/0001..0004` and builds the two modules into
`vendor/lib64/hw/`. The provider binaries in `vendor/` are not rebuilt (they
come from the emulator image; see the doc).

## Baked image (optional)

```bash
cd ../..   # repo root
docker build -f Dockerfile.android12-camera -t droid-kit:12-camera .
docker create --name droid-kit-12-img --privileged \
  --device /dev/video10:/dev/video0 -p 5558:5555 droid-kit:12-camera \
  androidboot.redroid_width=1080 androidboot.redroid_height=1920 \
  androidboot.redroid_dpi=480
docker start droid-kit-12-img
```

The image contains the same HAL/gralloc/provider/rc/media profiles and the
`ro.hardware.camera=v4l2` / `ro.hardware.gralloc=v4l2` properties. Verified:
1 camera device, facing Back, WebView label `camera2 0, facing back`.

## Host video source

```bash
../host/setup-v4l2loopback.sh
../host/feed.sh /path/to/video.mp4          # yuyv422 1280x720 by default
# or a test pattern:
ffmpeg -re -f lavfi -i testsrc2=size=1280x720:rate=30 \
  -pix_fmt yuyv422 -f v4l2 /dev/video10
```

## Run

```bash
PORT=5556 ./run.sh
```

`run.sh` uses `docker create` + `docker cp` (not `-v`) and sets
`ro.hardware.camera=v4l2` / `ro.hardware.gralloc=v4l2` in
`/vendor/build.prop`, then starts the container.

## Verify

```bash
./check-artifacts.sh
PORT=5556 ../verify/verify-camera.sh
```

Expected:

```text
ro.hardware.camera=v4l2
Number of camera devices: 1
Facing: Back
```

WebView check: `../verify/camtest/` (see its README). Verified output:

```text
I CAMTEST : console: label=camera2 0, facing back
I CAMTEST : console: frame 0 sum=856512 hash=2518866944 size=1280x720
I CAMTEST : console: requestVideoFrameCallback count in 3s=30
```

`camera2` is the Chromium prefix for the Camera2 API; `facing back` comes from
the HAL's `ANDROID_LENS_FACING_BACK`.
