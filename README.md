# droid-kit — Android 12 camera + 反检测（reDroid）

在 reDroid 12（Android 12 / API 31）上运行 legacy `camera.v4l2` HAL，并预置
Magisk（Zygisk）与 Xposed 模块。仓库只保留 Android 12 方案。

## 已验证

- 双摄：camera 0 后摄、camera 1 前摄
- WebView label：`camera2 0, facing back` / `camera2 1, facing front`
- 640x480 / 1280x720 / 1920x1080；系统相机拍照 1920x1080 JPEG
- 元数据一致性 13/13（distortion correction、flash/LED、sensor array、
  缩略图、固定对焦、三档分辨率）
- 首启自动安装：Magisk 31.1、Zygisk、LSPosed、Shamiko、PlayIntegrityFix、
  HMA-OSS、Magisk-DeviceSpoofer(Pixel 6a)、10 个 Xposed 模块、ReCam、
  电池伪装

## 镜像

```bash
./build.sh                    # droid-kit:12-camera
docker tag droid-kit:12-camera ghcr.io/wangsendi/droid-kit:12-camera
docker push ghcr.io/wangsendi/droid-kit:12-camera
```

推送需要带 `write:packages` 的 GitHub PAT（`docker login ghcr.io`）。

从镜像启动（宿主先准备两路 v4l2loopback 视频源）：

```bash
docker create --name droid-kit-12-cam2 --privileged \
  --device /dev/video10:/dev/video0 \
  --device /dev/video11:/dev/video1 \
  -p 5557:5555 \
  ghcr.io/wangsendi/droid-kit:12-camera \
  androidboot.redroid_width=1080 \
  androidboot.redroid_height=1920 \
  androidboot.redroid_dpi=480
docker start droid-kit-12-cam2
adb connect 127.0.0.1:5557
```

首次启动会自动完成 Magisk/模块安装并写入作用域，不需要重启容器。

## 准备（从源码构建）

### 1. 模块（放到 `modules/`）

| 文件 | 类型 | 来源 |
| --- | --- | --- |
| Shamiko.zip | Magisk（Zygisk） | https://github.com/LSPosed/LSPosed.github.io/releases |
| LSPosed-zygisk.zip | Magisk（Zygisk） | https://github.com/LSPosed/LSPosed/releases |
| PlayIntegrityFix.zip | Magisk（Zygisk） | https://github.com/KOWX712/PlayIntegrityFix/releases |
| HMA-OSS-zygisk.zip | Magisk（Zygisk） | https://github.com/frknkrc44/HMA-OSS/releases |
| GPS-Setter.apk | Xposed | https://github.com/Xposed-Modules-Repo/com.android1500.gpssetter |
| FakeSensor.apk | Xposed | https://github.com/qilin7762-netizen/FakeSensor |
| WaydroidNetworkSpoof.apk | Xposed | https://github.com/arkaroy14/waydroid_network_spoof/releases |
| HideMyDevice.apk | Xposed | https://github.com/imkamaran/HideMyDevice/releases |
| TelephonySpoofer.apk | Xposed | https://github.com/brianwalczak/TelephonySpoofer/releases |
| AndroidFaker.apk | Xposed | https://github.com/Android1500/AndroidFaker/releases |
| DeviceSpoofLab.apk | Xposed | https://github.com/yubunus/DeviceSpoofLab-Hooks/releases |
| PrivacyKit.apk | Xposed | https://github.com/Xposed-Modules-Repo/com.sal.privacykit/releases |
| PrivacyKitLite.apk | Xposed | https://github.com/Mohithash/privacy-kit-lite/releases |
| SpoofMyDevice.apk | Xposed | https://github.com/BuSung-dev/SpoofMyDevice/releases |
| Magisk-DeviceSpoofer-Pixel6a.zip | Magisk | https://github.com/L0NE-6/Magisk-DeviceSpoofer/releases |

一键下载（固定版本，已验证）：

```bash
cd modules/
curl -fLO https://github.com/LSPosed/LSPosed.github.io/releases/download/shamiko-414/Shamiko-v1.2.5-414-release.zip
mv Shamiko-v1.2.5-414-release.zip Shamiko.zip
curl -fLO https://github.com/LSPosed/LSPosed/releases/download/v1.9.2/LSPosed-v1.9.2-7024-zygisk-release.zip
mv LSPosed-v1.9.2-7024-zygisk-release.zip LSPosed-zygisk.zip
curl -fL -o PlayIntegrityFix.zip https://github.com/KOWX712/PlayIntegrityFix/releases/download/v4.9-inject-s/PlayIntegrityFix_v4.9-inject-s.zip
curl -fLO https://github.com/frknkrc44/HMA-OSS/releases/download/oss-177/HMA-OSS-ZYGISK-oss-177-release.zip
mv HMA-OSS-ZYGISK-oss-177-release.zip HMA-OSS-zygisk.zip
curl -fL -o GPS-Setter.apk https://github.com/Xposed-Modules-Repo/com.android1500.gpssetter/releases/download/v1.2.8/app-release.apk
curl -fL -o FakeSensor.apk https://github.com/qilin7762-netizen/FakeSensor/releases/download/v1.0.0/app-debug.apk
curl -fL -o WaydroidNetworkSpoof.apk https://github.com/arkaroy14/waydroid_network_spoof/releases/download/20260317-1.2.0/WaydroidNetworkSpoof-v1.2.0.apk
curl -fL -o HideMyDevice.apk https://github.com/imkamaran/HideMyDevice/releases/download/2-1.1.0/HideMyDevice-1.1.0-release.apk
curl -fL -o TelephonySpoofer.apk https://github.com/brianwalczak/TelephonySpoofer/releases/download/v1.0.0/TelephonySpoofer.apk
curl -fL -o AndroidFaker.apk https://github.com/Android1500/AndroidFaker/releases/download/v1.9.2/app-release.apk
curl -fL -o DeviceSpoofLab.apk https://github.com/yubunus/DeviceSpoofLab-Hooks/releases/download/v1.3/app-debug.apk
curl -fL -o PrivacyKit.apk https://github.com/Xposed-Modules-Repo/com.sal.privacykit/releases/download/112-3.7.1/PrivacyKit-3.7.1.apk
curl -fL -o PrivacyKitLite.apk https://github.com/Mohithash/privacy-kit-lite/releases/download/v0.4.0/app-release.apk
curl -fL -o SpoofMyDevice.apk https://github.com/BuSung-dev/SpoofMyDevice/releases/download/v2.0.1/app-debug.apk
curl -fLO https://github.com/L0NE-6/Magisk-DeviceSpoofer/releases/download/v31/Magisk-DeviceSpoofer_Google_40_v31.zip
unzip -p Magisk-DeviceSpoofer_Google_40_v31.zip "Pixel 6a (bluejay)/Pixel 6a (GB62Z).zip" > Magisk-DeviceSpoofer-Pixel6a.zip
rm Magisk-DeviceSpoofer_Google_40_v31.zip
```

### 2. ReCam（放到 `recam/`）

```bash
curl -fLO https://github.com/aimardcr/ReCam/releases/download/v0.1.4-rc.1/recam-cli-v0.1.4-rc.1-android-x86_64.zip
unzip recam-cli-v0.1.4-rc.1-android-x86_64.zip -d recam/
rm recam-cli-v0.1.4-rc.1-android-x86_64.zip
```

### 3. Android 12 camera HAL 依赖

- AOSP 12 源码树（默认 `/app/data/aosp12`）
- NDK r23c（`$AOSP_DIR/ndk/android-ndk-r23c`）
- 从 reDroid 12 导出的系统库（`$AOSP_DIR/rd12libs`）

详见 `docs/CAMERA-ANDROID12.md`。

## 构建

```bash
./build.sh                    # 编 HAL/provider + 构建 droid-kit:12-camera
./build.sh my-tag             # 自定义 tag
```

`build.sh` 会：

1. 检查 `modules/`、`recam/`、Magisk APK；
2. 调用 `camera/android12/build.sh` 编译 `camera.v4l2.so` / `gralloc.v4l2.so`；
3. 用 `Dockerfile.android12-camera` 构建镜像（相机 + Magisk/Xposed 模块）。

## 宿主视频源

```bash
camera/host/setup-v4l2loopback.sh       # /dev/video10 后摄 + /dev/video11 前摄
camera/host/feed.sh back.mp4            # VIDEO_NR=10
VIDEO_NR=11 camera/host/feed.sh front.mp4
```

## 验证

```bash
PORT=5557 camera/verify/verify-camera.sh
PORT=5557 camera/verify/verify-metadata.sh
```

相机/模块检查（容器内 root）：

```bash
docker exec droid-kit-12-cam2 /system/bin/sh -c \
  'ls /data/adb/modules; tail -20 /data/adb/.droid-kit/boot.log'
```

预期 Magisk 模块：

```text
hma_oss_zygisk  playintegrityfix  xj_bluejay  zygisk_lsposed  zygisk_shamiko
```

WebView `getUserMedia`：

```bash
camera/verify/camtest/build-apk.sh
adb install -r camera/verify/camtest/build/camtest.apk
adb shell pm grant org.droidkit.camtest android.permission.CAMERA
adb shell am start -n org.droidkit.camtest/.MainActivity
adb logcat -d | grep CAMTEST
```

## 目录

```text
camera/android12/              # HAL/gralloc 构建、补丁、provider 获取、run.sh
camera/host/                   # v4l2loopback + 视频源
camera/verify/                 # 相机/元数据验证 + WebView camtest
docker/                        # Magisk/模块首启安装脚本、bootanim.rc、sqlrun
modules/                       # 伪装模块（自行下载，不入库）
recam/                         # ReCam 二进制（自行下载，不入库）
docs/CAMERA-ANDROID12.md       # 完整方案/原理/注入/排错
docs/安卓12方案.md             # 原始方案
Dockerfile.android12-camera    # 唯一镜像定义：相机 + Magisk/Xposed
build.sh                       # 构建入口
```

## 限制

- 虚拟摄像头：不解决 reDroid/模拟器环境指纹，KYC/活体/银行风控仍可能识别。
- 无闪光灯、固定对焦（元数据如实报告，不假装支持）。
- 每个 v4l2loopback 同时只允许一个 reader；视频源必须在启动容器前喂好并保持运行。
- Android 12 WebView 只带 Camera2，label 前缀为 `camera2`。
