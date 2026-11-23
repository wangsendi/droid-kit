# AOSP 12 V4L2 HAL patches

These patches apply to the `hardware/libhardware` project of an AOSP 12 tree:

```bash
cd "$AOSP_DIR/hardware/libhardware"
git apply -p3 /path/to/0001-v4l2-report-back-camera.patch
git apply -p3 /path/to/0002-v4l2-hal-name.patch
git apply -p3 /path/to/0003-v4l2-multistream-mmap.patch
git apply -p3 /path/to/0004-gralloc-yuv.patch
```

What they change:

- `0001`: report `ANDROID_LENS_FACING_BACK` instead of `EXTERNAL`, and use a
  plausible phone aperture/focal length. This is what makes the browser see a
  normal back camera instead of an external webcam.
- `0002`: remove obvious "V4L2" / "AOSP" strings from the HAL module name.
- `0003`: make the HAL usable with v4l2loopback:
  - capture with a format the device actually supports instead of rejecting
    every multi-stream configuration (Camera1 asks for preview + JPEG,
    Camera2/WebView asks for preview + JPEG/YUV);
  - fill every output stream from the single V4L2 frame, converting as needed;
  - use MMAP buffers when the driver rejects `VIDIOC_REQBUFS(USERPTR)`
    (v4l2loopback only implements MMAP);
  - make `VIDIOC_STREAMON` idempotent (v4l2loopback returns `EBUSY` on a second
    call);
  - stop rejecting requests whose optional settings the HAL does not model.
- `0004`: add YUV support to the AOSP software gralloc (`gralloc.cpp`,
  `mapper.cpp`): allocate `YCbCr_420_888` / YV12 / NV21 / YUYV / YCbCr_422_SP
  and implement `(*lock_ycbcr)()`. This is what lets Camera2 ImageReaders get
  frames on reDroid, whose stock gralloc is RGB-only.

The HAL still reports `INFO_SUPPORTED_HARDWARE_LEVEL_LIMITED`. That is
intentional: changing it to `FULL` requires a large, consistent metadata set
(manual sensor, RAW, stream combinations), and an inconsistent `FULL` profile is
easier for an app to reject than an honest `LIMITED` one.
