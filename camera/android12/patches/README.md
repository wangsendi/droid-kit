# AOSP 12 V4L2 HAL patches

These patches apply to the `hardware/libhardware` project of an AOSP 12 tree:

```bash
cd "$AOSP_DIR/hardware/libhardware"
git apply /path/to/0001-v4l2-report-back-camera.patch
git apply /path/to/0002-v4l2-hal-name.patch
```

What they change:

- `0001`: report `ANDROID_LENS_FACING_BACK` instead of `EXTERNAL`, and use a
  plausible phone aperture/focal length. This is what makes the browser see a
  normal back camera instead of an external webcam.
- `0002`: remove obvious "V4L2" / "AOSP" strings from the HAL module name.

The HAL still reports `INFO_SUPPORTED_HARDWARE_LEVEL_LIMITED`. That is
intentional: changing it to `FULL` requires a large, consistent metadata set
(manual sensor, RAW, stream combinations), and an inconsistent `FULL` profile is
easier for an app to reject than an honest `LIMITED` one.
