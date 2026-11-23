# camtest

Minimal WebView app used to verify that Chrome/WebView `getUserMedia` sees the
injected Android 12 camera. It:

1. lists `navigator.mediaDevices.enumerateDevices()`;
2. calls `getUserMedia({video: {facingMode: 'environment'}})` and logs the
   track label / settings / capabilities;
3. draws the stream into a canvas and logs frame hashes and
   `requestVideoFrameCallback` counts, so "track exists but no frames" is
   visible in logcat.

Run:

```bash
adb install -r camtest.apk
adb shell pm grant org.droidkit.camtest android.permission.CAMERA
adb logcat -c
adb shell am start -n org.droidkit.camtest/.MainActivity
adb logcat -d | grep CAMTEST
```

Expected output on a working Android 12 setup:

```text
I CAMTEST : console: label=camera2 0, facing back
I CAMTEST : console: frame 0 sum=... hash=... size=1280x720
I CAMTEST : console: requestVideoFrameCallback count in 3s=30
```

`camera2` is Chromium's prefix for the Camera2 API (Android 5+); the
`facing back` part comes from `ANDROID_LENS_FACING_BACK` in the HAL metadata.

Build:

```bash
BUILD_TOOLS=$ANDROID_HOME/build-tools/33.0.2 \
ANDROID_JAR=$ANDROID_HOME/platforms/android-31/android.jar \
./build-apk.sh
```
