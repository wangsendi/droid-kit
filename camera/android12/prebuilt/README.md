# Prebuilt HAL/provider drop-in

If you already have a 64-bit Android 12 `camera.v4l2.so` and the matching
`android.hardware.camera.provider@2.4-service_64`, you can skip the AOSP build:

```text
camera/android12/prebuilt/
├── lib64/hw/camera.v4l2.so
├── lib64/hw/camera.device@*.so
├── lib64/android.hardware.camera.*.so
├── bin/hw/android.hardware.camera.provider@2.4-service_64
└── etc/init/android.hardware.camera.provider@2.4-service_64.rc
```

Then:

```bash
cd camera/android12
USE_PREBUILT=1 ./build.sh
```

`build.sh` copies this tree to `camera/android12/vendor/`. The files must be
built for Android 12 / x86_64 and the provider must be the 64-bit variant.
