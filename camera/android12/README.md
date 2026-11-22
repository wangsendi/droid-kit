# Android 12 camera path (legacy V4L2 HAL)

This directory implements the plan in `docs/安卓12方案.md`:

```text
Host v4l2loopback (/dev/video10)
        │ ffmpeg
        ▼
Redroid 12 container
  ├── camera.v4l2.so            → /vendor/lib64/hw/
  ├── camera provider 2.4       → /vendor/bin/hw/
  ├── provider rc               → /vendor/etc/init/
  ├── camera-ns-fix.rc          → /vendor/etc/init/
  ├── manifest-camera.xml       → /vendor/etc/vintf/manifest/
  └── ro.hardware.camera=v4l2
        ▼
Android Camera2 → Chrome/WebView getUserMedia
```

> The official Redroid 12 image does **not** contain `camera.v4l2.so` or a
> camera provider. That is why `build.sh` builds them from AOSP 12 instead of
> copying them out of the image.

## 1. Sync AOSP 12

```bash
cd camera/android12
./setup-aosp.sh
```

Default tree: `/app/data/aosp12`, branch `android-12.0.0_r34`, USTC mirror.
This downloads tens of GB.

## 2. Build HAL + provider

```bash
./build.sh
```

If the host is not suitable for AOSP 12 builds:

```bash
docker build -t droid-kit-aosp12-builder -f Dockerfile.builder .
BUILD_IN_DOCKER=1 ./build.sh
```

If you already have matching prebuilt artifacts, put them in `prebuilt/` and use:

```bash
USE_PREBUILT=1 ./build.sh
```

Artifacts are staged in `camera/android12/vendor/`:

```text
vendor/lib64/hw/camera.v4l2.so
vendor/lib64/hw/camera.device@*.so        # provider dependencies
vendor/lib64/android.hardware.camera.*     # provider impl/interface libs
vendor/lib64/libchrome.so / libexif.so     # if AOSP build needs them
vendor/bin/hw/android.hardware.camera.provider@2.4-service_64
vendor/etc/init/android.hardware.camera.provider@2.4-service_64.rc
```

The `_64` provider is used because the official Redroid 12 image is
64-bit-only. The 32-bit `android.hardware.camera.provider@2.4-service` will not
run there.

## 3. Host camera device

```bash
../host/setup-v4l2loopback.sh
../host/feed.sh /path/to/video.mp4
```

Use `PIX_FMT=yuv420p` (default) for the legacy HAL. `yuyv422` is accepted by
some V4L2 devices but the legacy HAL's format conversion expects
BGR32/YUV420/JPEG; if preview is black, switch the feed to YUYV and check
logcat.

## 4. Run (no image rebuild)

```bash
./run.sh
```

This starts `droid-kit-12-cam`, bind-mounting the HAL/provider/rc/manifest and
a patched `build.prop` with `ro.hardware.camera=v4l2`.

## 5. Verify

```bash
./check-artifacts.sh
../verify/verify-camera.sh
```

Expected:

```text
ro.hardware.camera=v4l2
Number of camera devices: 1
```

Browser:

```js
navigator.mediaDevices.getUserMedia({video: true}).then((s) => {
  const t = s.getVideoTracks()[0];
  console.log(t.label, t.getCapabilities(), t.getSettings());
});
```

## Reproducible image alternative

```bash
./build.sh --android12-camera   # from repo root
```

Builds `droid-kit:12-camera` from `Dockerfile.android12-camera`.

## Limitations

- `camera.v4l2` is deprecated and single-stream.
- `INFO_SUPPORTED_HARDWARE_LEVEL` remains `LIMITED`.
- `ld.config.txt` patching is experimental; if the provider cannot load the
  HAL, see `docs/CAMERA-ANDROID12.md` troubleshooting.
- If preview is black despite `dumpsys media.camera` showing one device, the
  problem is gralloc/format, not enumeration. Do not keep patching VINTF.
