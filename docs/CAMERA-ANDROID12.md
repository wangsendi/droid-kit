# Android 12 相机方案（legacy camera.v4l2）

本文对应 `docs/安卓12方案.md`，记录实际跑通的实现、注入方式和验证结果。

## 0. 结论先说

`redroid/redroid:12.0.0_64only-latest` 本身不包含相机：

- 没有 `/vendor/bin/hw/android.hardware.camera.provider@2.4-service_64`
- 没有 `/vendor/lib64/hw/camera.v4l2.so`
- `/vendor/lib64/hw/gralloc.redroid.so` 是 AOSP 软件 gralloc，只支持 RGB，
  不能分配 `YCbCr_420_888`

所以本方案做三件事：

1. 从 AOSP 12 **x86_64 模拟器镜像**取出 HIDL 2.4 provider（以及它依赖的
   `camera.device@*-impl`、HIDL 接口库、init rc）；
2. 从 AOSP 12 `hardware/libhardware` 的源码**手写编译** `camera.v4l2.so`
   （不依赖 Soong；本机 AOSP 树是部分同步/混合版本，Soong 无法完整解析）；
3. 从 `hardware/libhardware/modules/gralloc` 编译一个支持 YUV 的
   `gralloc.v4l2.so`，解决 Camera2 `ImageReader` 的 `YCbCr_420_888` 分配问题。

最终在 WebView 里 `getUserMedia` 可以拿到：

```text
label=camera2 0, facing back
size=1280x720
requestVideoFrameCallback count in 3s=30+
```

> Android 12 的 Chromium/WebView 走 Camera2 API，所以 label 前缀是
> `camera2`；`facing back` 来自 HAL 的 `ANDROID_LENS_FACING_BACK`。Camera1
> 时代的 `camera 0, facing back` 在本版本 Chromium 上不会出现。

## 1. 架构

```text
Host Linux
  v4l2loopback (/dev/video10, YUYV 1280x720)
        │ ffmpeg -pix_fmt yuyv422
        ▼
Redroid 12 container
  ├── /vendor/lib64/hw/camera.v4l2.so                  (自编)
  ├── /vendor/lib64/hw/gralloc.v4l2.so                 (自编, YUV)
  ├── /vendor/lib64/hw/android.hardware.camera.provider@2.4-impl.so
  ├── /vendor/lib64/android.hardware.camera.*.so
  ├── /vendor/lib64/camera.device@*-impl.so
  ├── /vendor/bin/hw/android.hardware.camera.provider@2.4-service_64
  ├── /vendor/etc/init/android.hardware.camera.provider@2.4-service_64.rc
  ├── /vendor/etc/vintf/manifest/manifest-camera.xml
  ├── /system/etc/media_profiles_V1_0.xml              (Camera1 shim 需要)
  └── /vendor/build.prop
        ro.hardware.camera=v4l2
        ro.hardware.gralloc=v4l2
        ▼
cameraserver → Camera2 → Chrome/WebView getUserMedia
```

## 2. 组件来源

### 2.1 provider：AOSP 12 x86_64 模拟器镜像

下载 `https://dl.google.com/android/repository/sys-img/android/x86_64-31_r05.zip`
（Android 12/API 31，AOSP 默认镜像），解开 `vendor.img` 后取出：

```text
vendor/bin/hw/android.hardware.camera.provider@2.4-service_64
vendor/etc/init/android.hardware.camera.provider@2.4-service_64.rc
vendor/lib64/hw/android.hardware.camera.provider@2.4-impl.so
vendor/lib64/android.hardware.camera.{common@1.0,device@1.0,
    device@3.2..3.7,metadata@3.2..3.6,provider@2.4,provider@2.4-legacy,
    provider@2.4-external}.so
vendor/lib64/camera.device@{1.0,3.2,3.3,3.4,3.4-external,3.5,3.5-external,
    3.6-external}-impl.so
vendor/lib64/libtinyxml2.so
```

`fetch-provider.sh` 会自动下载/解包这个镜像并把这些文件放进
`camera/android12/vendor/`：

```bash
cd camera/android12
./fetch-provider.sh
# 或使用已下载的镜像：
SYSTEM_IMAGE_ZIP=/path/to/x86_64-31_r05.zip ./fetch-provider.sh
```

这些文件在 `.gitignore` 里（约 2.4 MB），不随仓库提交。provider 是 Android 12
的 vendor 二进制，和 reDroid 12 的 system 库版本一致，可以直接运行。

### 2.2 HAL / gralloc：从 AOSP 12 源码手写编译

```bash
camera/android12/build.sh
```

`build.sh` 会：

1. 对 `$AOSP_DIR/hardware/libhardware` 应用 `patches/0001..0004`；
2. 用 NDK r23c 的 `x86_64-linux-android31-clang++` 编译：
   - `build-v4l2.sh` → `camera.v4l2.so`
   - `build-gralloc.sh` → `gralloc.v4l2.so`
3. 检查 `vendor/` 里的 provider 二进制与产物。

为什么不用 Soong：本机 AOSP 树是部分同步的混合树，Soong 解析阶段会因大量
无关模块缺失而失败；camera.v4l2 本身是普通 libhardware HAL，手写编译更可控。
HAL 链接的是 reDroid 12 系统里的库（`$AOSP_DIR/rd12libs`，由镜像导出）。

补丁：

| 补丁 | 作用 |
|---|---|
| `0001-v4l2-metadata-consistency.patch` | `is_front` 控制 BACK/FRONT；distortion correction；LED/flash 一致；固定对焦；1920x1080 sensor array；合法缩略图列表；光圈/焦距 |
| `0002-v4l2-dual-camera.patch` | 节点排序、双摄枚举（0 后摄 / 1 前摄）、模块名清理 |
| `0003-v4l2-multistream-mmap-multires.patch` | 多 stream 转换、MMAP 回退、STREAMON 幂等、放宽 settings、640x480/1280x720/1920x1080 缩放、`is_front` 传递 |
| `0004-gralloc-yuv.patch` | 软件 gralloc 支持 YUV_420_888/YV12/NV21/YUYV + `lock_ycbcr` |

`0003` 解决的实际问题：

- Camera1 配 2 路 stream（preview + JPEG），Camera2/WebView 还会加
  `YCbCr_420_888`；原 HAL 直接拒绝，报
  `V4L2 only supports 1 stream configuration at a time`。
- v4l2loopback 只支持 `V4L2_MEMORY_MMAP`，原 HAL 固定用 USERPTR，
  报 `REQBUFS failed: Invalid argument`。
- v4l2loopback 对重复 `VIDIOC_STREAMON` 返回 `EBUSY`。

`0004` 解决的实际问题：

```text
GraphicBufferAllocator: Failed to allocate (1280 x 720) ... format 35 usage 33: 3
```

reDroid 的软件 gralloc 只认 RGB；Camera2 `ImageReader` 要
`YCbCr_420_888`。`gralloc.v4l2.so` 增加 YUV 分配和 `(*lock_ycbcr)()`，
通过 `ro.hardware.gralloc=v4l2` 选中。

### 2.3 media profiles

reDroid 12 没有 `/system/etc/media_profiles_V1_0.xml`。Camera1 shim
（`Camera2Client`）在初始化时用视频编码器能力算预览尺寸，缺文件会得到空
列表并拒绝打开相机：

```text
Camera2-Parameters: generated preview size list is empty!!
```

`files/media_profiles_V1_0.xml` 由 `run.sh` 注入到
`/system/etc/media_profiles_V1_0.xml`。

## 3. Host：准备视频源

```bash
camera/host/setup-v4l2loopback.sh
camera/host/feed.sh /path/to/video.mp4
```

默认：

```text
/dev/video10
1280x720 @ 30
pix_fmt=yuyv422
card_label=Camera
```

也可以不用文件，直接测试图案：

```bash
ffmpeg -re -f lavfi -i testsrc2=size=1280x720:rate=30 \
  -pix_fmt yuyv422 -f v4l2 /dev/video10
```

说明：

- HAL 会优先选择设备真实支持的格式再转换到各条 stream；YUYV 最稳。
- 如果宿主机 `/dev/video10` 是在开发容器里 `mknod` 的，Docker daemon 看不到，
  `--device` 会报 `no such file or directory`；需要在宿主机 `/dev` 里创建同名
  设备节点（本仓库的 `run.sh` 用 `--device /dev/video10:/dev/video0`）。

## 4. 运行（不重打包）

```bash
cd camera/android12
# 当前保留的是第 9 节的 5557 双摄容器；下面只是单摄模式的示例端口
PORT=5558 ./run.sh
```

`run.sh` 使用 `docker create` + `docker cp` 注入，**不要用 `-v` 挂不存在的
目标文件**（Docker 会创建成目录）：

1. HAL、gralloc、provider、provider/device impl 库、HIDL 接口库；
2. provider rc、`camera-ns-fix.rc`、VINTF fragment；
3. `media_profiles_V1_0.xml` → `/system/etc/`；
4. 修改 `/vendor/build.prop`：
   `ro.hardware.camera=v4l2`、`ro.hardware.gralloc=v4l2`；
5. `docker start`。

## 5. 验证

```bash
PORT=5557 camera/verify/verify-camera.sh
```

关键输出：

```text
ro.hardware.camera=v4l2
Number of camera devices: 1
Facing: Back
```

浏览器/WebView 验证（`camera/verify/camtest`）：

```bash
BUILD_TOOLS=$ANDROID_HOME/build-tools/33.0.2 \
ANDROID_JAR=$ANDROID_HOME/platforms/android-31/android.jar \
  camera/verify/camtest/build-apk.sh
adb install -r camera/verify/camtest/build/camtest.apk
adb shell pm grant org.droidkit.camtest android.permission.CAMERA
adb logcat -c
adb shell am start -n org.droidkit.camtest/.MainActivity
adb logcat -d | grep CAMTEST
```

实测（reDroid 12 / API 31，v4l2loopback + testsrc2）：

```text
I CAMTEST : console: label=camera2 0, facing back
I CAMTEST : console: settings={"facingMode":"environment","width":1280,
              "height":720,"frameRate":30,...}
I CAMTEST : console: frame 0 sum=856512 hash=2518866944 size=1280x720
I CAMTEST : console: requestVideoFrameCallback count in 3s=30
I CAMTEST : console: DONE
```

相机 App 的拍照路径也已验证：点击快门后生成
`/sdcard/Pictures/IMG_*.jpg`，`file` 显示为 1280x720 JPEG（HAL 的 BLOB
输出经 ImageProcessor 编码），说明多 stream + JPEG 路径正常。

`dumpsys media.camera` 同时显示：

```text
Number of camera devices: 1
API1 info:
  Facing: Back
API2 camera characteristics:
  android.lens.facing: [BACK]
```

## 6. 常见问题

| 现象 | 原因 | 处理 |
|---|---|---|
| `Could not load camera HAL module: -2` | HAL 不在 `/vendor/lib64/hw` | 重新 `run.sh`，确认 `docker cp` 路径 |
| `library "libgui.so" not found` / `libcamera_client` | HAL 误链接系统私有库 | 本方案已把 `CameraMetadata.cpp` 静态编进 HAL，不依赖 `libcamera_client` |
| provider 起不来，缺 `android.hidl.allocator@1.0.so` | 系统库不在 vendor namespace | `vendor/lib64/android.hidl.allocator@1.0.so` 已随 run.sh 注入 |
| 0 个设备 | `ro.hardware.camera` 没生效 | `getprop ro.hardware.camera` 应为 `v4l2` |
| `V4L2 only supports 1 stream` | 未应用 `0003` | 重新 `build.sh` |
| `REQBUFS failed: Invalid argument` | 驱动只支持 MMAP | `0003` 已含 MMAP 回退 |
| `Failed to allocate ... format 35` | gralloc 不支持 YUV | 确认 `ro.hardware.gralloc=v4l2` 且 `gralloc.v4l2.so` 已注入 |
| `generated preview size list is empty` | 缺 media profiles | 确认 `/system/etc/media_profiles_V1_0.xml` 存在 |
| 有 track 但黑屏/无帧 | 未应用 `0003` 的每路转换或 STREAMON 幂等 | 看 `logcat -s V4L2Wrapper V4L2Camera` |
| 浏览器 label 带 `camera2` 前缀 | Android 12 Chromium 使用 Camera2 API | 正常；facing 为 `back` 即符合要求 |
| Android 13 上失败 | HIDL/VINTF 变化 | 本方案只针对 Android 12 |

## 7. 可复现性

- 源码补丁：`camera/android12/patches/0001..0004`，`build.sh` 自动应用。
- HAL/gralloc 编译：`build-v4l2.sh`、`build-gralloc.sh`（NDK r23c + reDroid 12
  导出的 `rd12libs`）。
- provider 等预编译二进制：`./fetch-provider.sh` 从
  `x86_64-31_r05.zip` 自动解包到 `camera/android12/vendor/`（被 `.gitignore`
  忽略，约 2.4 MB）。它们不是本机 AOSP 构建产物。
- 运行脚本：`run.sh` + `files/`（rc、VINTF、media profiles）。
- 验证：`camera/verify/verify-camera.sh` 和 `camera/verify/camtest/`。

## 8. 预构建镜像（可选）

除运行期注入外，仓库还提供把上述文件直接烘进镜像的变体：

```bash
cd /path/to/droid-kit
docker build -f Dockerfile.android12-camera -t droid-kit:12-camera .
docker create --name droid-kit-12-img --privileged \
  --device /dev/video10:/dev/video0 -p 5558:5555 \
  droid-kit:12-camera \
  androidboot.redroid_width=1080 \
  androidboot.redroid_height=1920 \
  androidboot.redroid_dpi=480
docker start droid-kit-12-img
```

该镜像包含 HAL、YUV gralloc、provider/impl、rc、VINTF、media profiles，以及
`ro.hardware.camera=v4l2` / `ro.hardware.gralloc=v4l2`。

已实测：`dumpsys media.camera` 为 1 台设备、`Facing: Back`；WebView
`getUserMedia` 得到 `camera2 0, facing back` 和 1280x720 帧。

> 这个变体会在 Redroid 12 之上增加一层很小的文件层；如果坚持“完全不重打包”，
> 用 `run.sh` 的运行期注入方式即可，两者产物一致。


## 9. 双摄 + 多分辨率 + 元数据一致性（5557）

在原有单后摄方案之上又做了一轮升级，运行在 `droid-kit-12-cam2`（5557）。
旧的单后摄 5556 容器已清理，当前只保留 5557。

### 9.1 Host：两个 v4l2loopback

```bash
camera/host/setup-v4l2loopback.sh     # devices=2 video_nr=10,11
camera/host/feed.sh /path/to/back.mp4 # VIDEO_NR=10
VIDEO_NR=11 camera/host/feed.sh /path/to/front.mp4
```

`exclusive_caps=1`，所以前摄/后摄都必须在启动容器前喂流；否则没喂的那个不会
报告 capture 能力。

### 9.2 启动 5557

```bash
cd camera/android12
PORT=5557 ./run-5557.sh
```

映射：

```text
host /dev/video10 -> /dev/video0  camera 0, back
host /dev/video11 -> /dev/video1  camera 1, front
```

### 9.3 元数据修复

- 2 台设备：id 0 `Facing: Back`，id 1 `Facing: Front`
- `ANDROID_DISTORTION_CORRECTION_AVAILABLE_MODES = {OFF}`
- `FLASH_INFO_AVAILABLE = FALSE`，`LED_AVAILABLE_LEDS` 真正为空（不再误报 TRANSMIT）
- `SENSOR_INFO_PIXEL_ARRAY_SIZE` / `ACTIVE_ARRAY_SIZE` = 1920x1080，
  `PHYSICAL_SIZE` = 5.76x3.24 mm
- `JPEG_AVAILABLE_THUMBNAIL_SIZES` 4 个 int（两对 0x0）
- 固定对焦：AF 仅 OFF，最小对焦距离 0
- 输出尺寸：640x480 / 1280x720 / 1920x1080
- 设备仍为 `INFO_SUPPORTED_HARDWARE_LEVEL_LIMITED`（一致的无闪光/固定对焦档位比
  虚假的 FULL 更稳）

### 9.4 验证结果

```bash
PORT=5557 camera/verify/verify-camera.sh
PORT=5557 camera/verify/verify-metadata.sh
```

`verify-metadata.sh` 实测 `13 passed, 0 failed`：

```text
PASS  camera count is 2
PASS  API1 facing Back present
PASS  API1 facing Front present
PASS  distortionCorrection.availableModes contains OFF
PASS  flash.info.available is FALSE
PASS  led.availableLeds has no TRANSMIT (empty list)
PASS  sensor.info.pixelArraySize is 1920 1080
PASS  sensor.info.activeArraySize ends with 1920 1080
PASS  jpeg.availableThumbnailSizes has 4 values
PASS  stream config 640x480 present
PASS  stream config 1280x720 present
PASS  stream config 1920x1080 present
```

WebView（camtest）实测：

```text
back label=camera2 0, facing back
back1080 label=camera2 0, facing back
front label=camera2 1, facing front
front1080 label=camera2 1, facing front
back frame size=640x480 ... vfc=16
front frame size=640x480 ... vfc=17
```

系统相机 App 拍照在 5557 上生成了 1920x1080 JPEG，说明多分辨率 + 1080p
缩放 + JPEG BLOB 路径都正常。

### 9.5 说明

- 当前只保留 5557 双摄/多分辨率容器；旧的 5556 单后摄容器已清理。
- WebView 125 仍使用 Camera2，所以 label 前缀是 `camera2`：
  后摄 `camera2 0, facing back`，前摄 `camera2 1, facing front`。
- 这个升级仍是“虚拟摄像头”，不解决 redroid/环境指纹；只是让相机功能更完整、
  元数据更自洽。
