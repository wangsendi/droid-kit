# camtest

Minimal WebView app used to verify that Chrome/WebView `getUserMedia` sees the
injected Android 12 cameras. It:

1. lists `navigator.mediaDevices.enumerateDevices()`;
2. calls `getUserMedia({video: {facingMode: 'environment'}})` and logs the
   track label / settings / capabilities;
3. lists the devices again now that permission is granted (labels and ids are
   only populated after the first successful `getUserMedia`), so both cameras
   show up in the log;
4. draws the stream into a canvas and logs frame hashes and
   `requestVideoFrameCallback` counts, so "track exists but no frames" is
   visible in logcat;
5. stops the back stream, opens `getUserMedia({video: {facingMode: 'user'}})`
   and logs the front track label / settings / capabilities. The back stream is
   stopped first because the legacy HAL may not allow two open cameras.

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
I CAMTEST : console: devices=[...]
I CAMTEST : console: label=camera2 0, facing back
I CAMTEST : console: devices-after-permission=[{"kind":"videoinput","label":"camera2 0, facing back",...},{"kind":"videoinput","label":"camera2 1, facing front",...}]
I CAMTEST : console: frame 0 sum=... hash=... size=1280x720
I CAMTEST : console: requestVideoFrameCallback count in 3s=30
I CAMTEST : console: front label=camera2 1, facing front
I CAMTEST : console: front settings={"facingMode":"user",...}
I CAMTEST : console: DONE
```

`camera2` is Chromium's prefix for the Camera2 API (Android 5+); the
`facing back` / `facing front` parts come from `ANDROID_LENS_FACING_BACK` and
`ANDROID_LENS_FACING_FRONT` in the HAL metadata. `DONE` is logged after the
front-camera probe, so a missing `DONE` means the front camera could not be
opened. Before permission is granted the labels/ids are empty; that is why the
device list is logged twice.

Build:

```bash
BUILD_TOOLS=$ANDROID_HOME/build-tools/33.0.2 \
ANDROID_JAR=$ANDROID_HOME/platforms/android-31/android.jar \
./build-apk.sh
```
