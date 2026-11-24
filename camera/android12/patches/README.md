# AOSP 12 V4L2 HAL / gralloc patches

These patches apply to the `hardware/libhardware` project of an AOSP 12 tree.
`camera/android12/build.sh` applies them automatically (in file-name order):

```bash
cd "$AOSP_DIR/hardware/libhardware"
for p in /path/to/camera/android12/patches/*.patch; do
  git apply -p3 "$p"
done
```

What they change:

- `0001-v4l2-metadata-consistency.patch`
  - `ANDROID_LENS_FACING` is now selected by a new `is_front` argument
    (`BACK` for camera 0, `FRONT` for camera 1) instead of always `EXTERNAL`.
  - Adds `ANDROID_DISTORTION_CORRECTION_AVAILABLE_MODES = {OFF}`.
  - Fixes the flash/LED inconsistency: flash is unavailable and
    `ANDROID_LED_AVAILABLE_LEDS` is a truly empty byte array (a
    `Property<uint8_t>({}, 0)` used to mean TRANSMIT).
  - Fixed-focus profile: AF modes `{OFF}`, minimum focus distance `0.0`.
  - `ANDROID_SENSOR_INFO_PIXEL_ARRAY_SIZE` /
    `ACTIVE_ARRAY_SIZE` = 1920x1080 and a matching 5.76x3.24 mm
    `PHYSICAL_SIZE`.
  - `ANDROID_JPEG_AVAILABLE_THUMBNAIL_SIZES` has 4 ints (two `0x0` pairs),
    which the framework requires.
  - Plausible phone aperture/focal length (1.8 / 4.3 mm).

- `0002-v4l2-dual-camera.patch`
  - Sorts `/dev/video*` nodes numerically and enumerates two cameras:
    camera 0 = back, camera 1 = front.
  - Keeps camera ids dense, fixes the leaked `closedir()`, cleans the HAL
    module name ("Camera HAL v3" / "Google").

- `0003-v4l2-multistream-mmap-multires.patch`
  - Multi-stream output: capture once and convert into every requested
    stream buffer (preview + JPEG + YUV callbacks).
  - MMAP fallback when `VIDIOC_REQBUFS(USERPTR)` is rejected
    (v4l2loopback only implements MMAP).
  - Idempotent `VIDIOC_STREAMON` (v4l2loopback returns EBUSY on a second
    call) and best-effort request settings.
  - Advertises 640x480 / 1280x720 / 1920x1080 output; the HAL captures at a
    real device size and scales per stream.
  - Passes `is_front` through `V4L2Camera::NewV4L2Camera` into the metadata
    factory and keeps the existing stream/MAP behaviour.

- `0004-gralloc-yuv.patch`
  - Software gralloc allocates `YCbCr_420_888` / YV12 / NV21 / YUYV /
    YCbCr_422_SP and implements `(*lock_ycbcr)()`. Without it Camera2
    ImageReaders fail with "Failed to allocate ... format 35".

The HAL still reports `INFO_SUPPORTED_HARDWARE_LEVEL_LIMITED`. That is
intentional: a consistent LIMITED profile (fixed focus, no flash, no RAW) is
less suspicious than an inconsistent FULL one.
