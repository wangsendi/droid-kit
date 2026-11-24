# Camera support — Android 12 legacy V4L2

- `camera/android12/` — builds `camera.v4l2.so` + YUV gralloc + HIDL 2.4
  provider staging, patches, and the runtime injection scripts (`run.sh`,
  `run-5557.sh`).
- `camera/host/` — creates two v4l2loopback devices (`video10` back,
  `video11` front) and feeds them with ffmpeg.
- `camera/verify/` — `verify-camera.sh`, `verify-metadata.sh`, and the
  WebView `camtest` app (back/front + explicit sizes).

Start with `camera/android12/README.md`; full design and troubleshooting are in
`docs/CAMERA-ANDROID12.md`.
