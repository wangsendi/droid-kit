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
`ro.hardware.camera=v4l2` / `ro.hardware.gralloc=v4l2` properties. Rebuild the
image after changing the HAL. With both host devices mapped
(`--device /dev/video10:/dev/video0 --device /dev/video11:/dev/video1`) it
exposes 2 cameras (0 back, 1 front).

## Host video source

```bash
../host/setup-v4l2loopback.sh
../host/feed.sh /path/to/video.mp4          # back, yuyv422 1280x720 by default
# or a test pattern:
ffmpeg -re -f lavfi -i testsrc2=size=1280x720:rate=30 \
  -pix_fmt yuyv422 -f v4l2 /dev/video10
```

`setup-v4l2loopback.sh` creates two devices: `/dev/video10` (back, camera 0)
and `/dev/video11` (front, camera 1). Feed both before starting the container:
with `exclusive_caps=1` an unfed loopback node does not advertise capture
support, and the legacy HAL has no hotplug.

```bash
../host/feed.sh back.mp4                 # VIDEO_NR=10 by default
VIDEO_NR=11 ../host/feed.sh front.mp4
```

`run.sh` maps `VIDEO_DEV` (default `/dev/video10`) to `/dev/video0` and, if
`VIDEO_DEV2` (default `/dev/video11`) exists, also
`--device /dev/video11:/dev/video1`. With only the back device present the
container still starts and exposes one camera.

## Run

```bash
# single back camera (fallback container, 5556)
PORT=5556 ./run.sh

# dual camera + 640x480/1280x720/1920x1080 metadata (5557)
PORT=5557 ./run-5557.sh
```

`run.sh` uses `docker create` + `docker cp` (not `-v`) and sets
`ro.hardware.camera=v4l2` / `ro.hardware.gralloc=v4l2` in
`/vendor/build.prop`, then starts the container.

## Verify

```bash
./check-artifacts.sh
PORT=5557 ../verify/verify-camera.sh
PORT=5557 ../verify/verify-metadata.sh
```

Expected with both feeds running:

```text
Number of camera devices: 2
Facing: Back
Facing: Front
```

`verify-metadata.sh` checks the upgraded static metadata (13 checks):

```text
PASS  camera count is 2
PASS  API1 facing Back present
PASS  API1 facing Front present
PASS  distortionCorrection.availableModes contains OFF
PASS  flash.info.available is FALSE
PASS  led.availableLeds has no TRANSMIT (empty list)
PASS  sensor.info.pixelArraySize is 1920 1080
PASS  sensor.info.activeArraySize ends with 1920 1080
PASS  jpeg.availableThumbnailSizes has 4 values
PASS  stream config 640x480 present
PASS  stream config 1280x720 present
PASS  stream config 1920x1080 present
```

WebView check: `../verify/camtest/` (see its README). Verified output on 5557:

```text
I CAMTEST : console: back label=camera2 0, facing back
I CAMTEST : console: front label=camera2 1, facing front
I CAMTEST : console: back frame size=640x480 ... vfc=16
I CAMTEST : console: front frame size=640x480 ... vfc=17
```

The stock camera app produces a 1920x1080 JPEG on 5557, which exercises the
1080p upscale + JPEG path. `camera2` is the Chromium prefix for the Camera2
API; the facing values come from the HAL metadata.
