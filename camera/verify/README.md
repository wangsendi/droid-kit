# Camera verification

Three levels, from the HAL up to the browser.

## 1. HAL / provider / camera service

```bash
PORT=5556 ./verify-camera.sh
```

Expected (exit code 0):

```text
ro.hardware.camera=v4l2
android.hardware.camera.provider@2.4::ICameraProvider/legacy/0
Number of camera devices: 1
    Facing: Back
```

## 2. WebView `getUserMedia`

`camtest/` is a minimal WebView app that exercises the same Chromium capture
path as Chrome. See `camtest/README.md`.

```bash
cd camtest
BUILD_TOOLS=$ANDROID_HOME/build-tools/33.0.2 \
ANDROID_JAR=$ANDROID_HOME/platforms/android-31/android.jar \
  ./build-apk.sh
adb install -r build/camtest.apk
adb shell pm grant org.droidkit.camtest android.permission.CAMERA
adb logcat -c
adb shell am start -n org.droidkit.camtest/.MainActivity
adb logcat -d | grep CAMTEST
```

Expected:

```text
I CAMTEST : console: label=camera2 0, facing back
I CAMTEST : console: frame 0 sum=... hash=... size=1280x720
I CAMTEST : console: requestVideoFrameCallback count in 3s=30
I CAMTEST : console: DONE
```

> Android 12's Chromium/WebView only ships `VideoCaptureCamera2` (verified in
> WebView 125), so the label prefix is `camera2`. The `facing back` part comes
> from `ANDROID_LENS_FACING_BACK` in the HAL metadata. The Camera1-era
> `camera 0, facing back` label cannot be produced by this WebView.

## 3. Camera app preview / still capture

Open `com.android.camera2`, grant CAMERA/location, dismiss the first-run
screens. The preview shows the v4l2 feed. Pressing the shutter writes
`/sdcard/Pictures/IMG_*.jpg`; `file` reports a 1280x720 JPEG:

```text
JPEG image data ... 1280x720, components 3
```

This exercises the HAL's multi-stream + JPEG (BLOB) path, not only preview.
