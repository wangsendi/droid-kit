# Camera support

Two independent paths live here:

1. **Android 12 legacy V4L2 HAL** (`camera/android12/`)
   - Implements `docs/安卓12方案.md`.
   - Builds `camera.v4l2.so` + HIDL 2.4 provider from AOSP 12.
   - Runtime injection via `run.sh` (bind mounts, no rebuild).
   - Best for a browser `getUserMedia` device that looks like a normal
     back-facing camera.

2. **Android 13 external camera provider** (planned/optional)
   - Official AOSP path for USB UVC webcams.
   - Accepts MJPEG, supports hotplug.
   - Not implemented in this directory yet; the Android 12 path is the
     requested primary route.

Host-side helpers:

```text
camera/host/setup-v4l2loopback.sh   # create /dev/videoN
camera/host/feed.sh                 # feed file/URL/camera into it
camera/verify/verify-camera.sh      # adb checks + browser snippet
```

Start with `camera/android12/README.md`.
