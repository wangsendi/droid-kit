# Android 12 相机方案（legacy camera.v4l2）

本文对应 `docs/安卓12方案.md`，并记录实际实现与验证方式。

## 0. 先说明一个硬前提

官方 Redroid 12 镜像**不包含**：

```text
/system/lib64/hw/camera.v4l2.so
/vendor/lib64/hw/camera.v4l2.so
/vendor/bin/hw/android.hardware.camera.provider@2.4-service_64
```

对 `redroid/redroid:12.0.0_64only-latest` 完整解包检查，`camera.v4l2.so`
不存在，`/vendor/bin/hw` 也没有任何 camera provider；VINTF 没有 camera
声明，`ro.hardware.camera` 未设置。

因此方案中的“从官方镜像抠出原版 HAL”这一步无法直接执行。本仓库的做法是：

> 从 AOSP 12 源码编译 `camera.v4l2.so` 和 HIDL 2.4 provider，然后再按原方案
> 做 bind-mount 注入。

## 1. 架构

```text
Host Linux
  v4l2loopback (/dev/video10)
        │ ffmpeg
        ▼
Redroid 12 container
  ├── /vendor/lib64/hw/camera.v4l2.so              (AOSP 12 build, patched)
  ├── /vendor/bin/hw/android.hardware.camera.provider@2.4-service_64
  ├── /vendor/etc/init/android.hardware.camera.provider@2.4-service_64.rc
  ├── /vendor/etc/init/camera-ns-fix.rc
  ├── /vendor/etc/vintf/manifest/manifest-camera.xml
  └── ro.hardware.camera=v4l2
        ▼
cameraserver → Camera2 → Chrome/WebView getUserMedia
```

## 2. 构建 AOSP 12 HAL/provider

```bash
cd camera/android12
./setup-aosp.sh          # 同步 AOSP 12（约几十 GB）
./build.sh               # 应用补丁并编译
```

如果宿主机不适合直接编译 AOSP 12：

```bash
docker build -t droid-kit-aosp12-builder -f Dockerfile.builder .
BUILD_IN_DOCKER=1 ./build.sh
```

产物：

```text
camera/android12/vendor/lib64/hw/camera.v4l2.so
camera/android12/vendor/lib64/hw/camera.device@*.so
camera/android12/vendor/lib64/android.hardware.camera.*.so
camera/android12/vendor/bin/hw/android.hardware.camera.provider@2.4-service_64
camera/android12/vendor/etc/init/android.hardware.camera.provider@2.4-service_64.rc
```

> 官方 Redroid 12 是 64-bit only，所以必须用 `_64` provider；32 位的
> `android.hardware.camera.provider@2.4-service` 在 64only 镜像里没有 32 位
> linker/libc，起不来。

补丁：

- `patches/0001-v4l2-report-back-camera.patch`
  - `ANDROID_LENS_FACING_EXTERNAL` → `ANDROID_LENS_FACING_BACK`
  - 光圈/焦距改成手机常见值
- `patches/0002-v4l2-hal-name.patch`
  - 去掉明显的 V4L2/AOSP 模块名

## 3. Host：准备视频源

```bash
camera/host/setup-v4l2loopback.sh
camera/host/feed.sh /path/to/video.mp4
```

默认：

```text
/dev/video10
1920x1080 @ 30
pix_fmt=yuv420p
card_label=Camera
```

说明：

- 老 V4L2 HAL 要求 `BGR32 / YUV420 / JPEG`，所以默认喂 `yuv420p`。
- 如果你坚持 `yuyv422`，可能只枚举、不出帧；先看 `logcat`。
- `card_label` 不要带 `Virtual`、`Loopback`、`v4l2` 等字样。

## 4. 运行（不重打包）

```bash
cd camera/android12
./run.sh
```

`run.sh` 会：

1. 从 base image 取出 `/vendor/build.prop` 和 `/system/build.prop`；
2. 追加 `ro.hardware.camera=v4l2`；
3. 启动 `droid-kit-12-cam`；
4. bind-mount HAL、provider、provider rc、linker fix、VINTF fragment、prop。

对应 Docker 参数：

```bash
docker run -itd --privileged \
  --name droid-kit-12-cam \
  --device /dev/video10:/dev/video0 \
  -v $PWD/vendor/lib64/hw/camera.v4l2.so:/vendor/lib64/hw/camera.v4l2.so:ro \
  -v $PWD/vendor/bin/hw/android.hardware.camera.provider@2.4-service_64:/vendor/bin/hw/android.hardware.camera.provider@2.4-service_64:ro \
  -v $PWD/vendor/etc/init/android.hardware.camera.provider@2.4-service_64.rc:/vendor/etc/init/android.hardware.camera.provider@2.4-service_64.rc:ro \
  -v $PWD/files/camera-ns-fix.rc:/vendor/etc/init/camera-ns-fix.rc:ro \
  -v $PWD/files/manifest-camera.xml:/vendor/etc/vintf/manifest/manifest-camera.xml:ro \
  -v $PWD/vendor/prop/vendor-build.prop:/vendor/build.prop:ro \
  -p 5555:5555 \
  redroid/redroid:12.0.0_64only-latest \
  androidboot.redroid_width=1080 \
  androidboot.redroid_height=1920 \
  androidboot.redroid_dpi=480
```

## 5. 验证

```bash
camera/verify/verify-camera.sh
```

关键输出：

```text
ro.hardware.camera=v4l2
Number of camera devices: 1
```

### 分层验收

| 层级 | 命令 | 通过标准 | 失败含义 |
|---|---|---|---|
| provider 注册 | `adb shell 'lshal \| grep -i camera'` | 出现 `ICameraProvider/legacy/0` | VINTF/rc/二进制问题 |
| 设备枚举 | `dumpsys media.camera` | `Number of camera devices: 1` | HAL 未加载/无 `/dev/video*` |
| 帧 | 打开 Open Camera | 预览有画面 | 格式/gralloc |
| 浏览器 | `getUserMedia` | 有 video track | WebView/权限/相机 id |

不要跳过 provider 注册直接看浏览器；`getUserMedia` 失败时很难判断是 HAL 还是 WebView。

浏览器：

```js
navigator.mediaDevices.enumerateDevices().then(console.log)

navigator.mediaDevices.getUserMedia({video: true}).then((s) => {
  const t = s.getVideoTracks()[0];
  console.log('label:', t.label);
  console.log('capabilities:', t.getCapabilities());
  console.log('settings:', t.getSettings());
});
```

期望：

- `label` 不含 `virtual` / `v4l2` / `loopback`
- `facingMode` 为 `environment`（或至少不是 external）
- `getCapabilities()` 有 width/height/frameRate
- 预览不黑屏

## 6. 常见问题

| 现象 | 原因 | 处理 |
|---|---|---|
| `Could not load camera HAL module: -2` | HAL 不在 `/vendor/lib64/hw` | 确认 bind mount 路径 |
| provider 没起来 | VINTF 未声明 `legacy/0` | 检查 `/vendor/etc/vintf/manifest/manifest-camera.xml` |
| 0 个设备 | `ro.hardware.camera` 没生效 | 检查 `getprop ro.hardware.camera`；确认 build.prop bind mount |
| provider 崩溃/找不到 libcamera_client | linker namespace | 检查 `camera-ns-fix.rc` 是否执行；`ld.config.txt` 是否包含 `/system/lib64` |
| 有设备但黑屏 | gralloc/格式不兼容 | 换 `PIX_FMT=yuyv422` 或改 HAL 格式转换；这是最难的一层 |
| 浏览器 label 仍异常 | HAL metadata 不够 | 确认补丁已生效（`LENS_FACING_BACK`），camera id 为 0 |
| Android 13 上失败 | HIDL/VINTF 变化 | 本方案只针对 Android 12 |

### 6.1 gralloc 风险（重要）

Redroid 自带的 `gralloc.redroid.so` 是给显示/视频用的，不一定实现 Camera
需要的 `gralloc_lock_ycbcr`，也不一定接受 `YCbCr_420_888` /
`IMPLEMENTATION_DEFINED`。典型失败：

```text
GraphicBufferAllocator: Failed to allocate (4 x 4) ... format 43/56
```

或：

```text
ExtCamUtils: formatConvert: unsupported flexible yuv layout
```

如果 `dumpsys media.camera` 已经是 1，但预览/拍照黑屏，先看：

```bash
adb logcat -d | grep -iE 'gralloc|GraphicBuffer|lock_ycbcr|formatConvert'
```

这说明问题在 gralloc，不在 VINTF/HAL 加载。可选处理：

1. 用 droidpool 的 gralloc camera 补丁适配 Redroid 12 的
   `vendor/redroid/gralloc`，重新编 `gralloc.redroid.so` 并 bind-mount；
2. 或改用 Android 13 external camera provider 路线（它同样需要 gralloc 补丁，
   但 AOSP 13 的路径和社区补丁更成熟）；
3. 或直接用真机。

不要把“设备数 = 1”当成相机可用；必须验证预览/拍照。

## 7. 限制与检测

- `camera.v4l2` 是已废弃 HAL，单 stream、无热插拔、Camera1 基本不可用。
- 即使 `LENS_FACING_BACK`，`INFO_SUPPORTED_HARDWARE_LEVEL_LIMITED` 仍在；
  强行报 `FULL` 需要补齐大量 metadata，反而更容易失败。
- 浏览器 `getUserMedia` 只验证“能拿到流”，不等于能过活体/风控。
- 如果目标 App 做帧分析、活体、USB/驱动检测，虚拟摄像头仍然会被识别；
  这种场景应使用真机。

## 8. 仓库内相关文件

```text
camera/android12/setup-aosp.sh
camera/android12/build.sh
camera/android12/run.sh
camera/android12/Dockerfile.builder
camera/android12/patches/*.patch
camera/android12/files/manifest-camera.xml
camera/android12/files/camera-ns-fix.rc
camera/host/setup-v4l2loopback.sh
camera/host/feed.sh
camera/verify/verify-camera.sh
Dockerfile.android12-camera
```
