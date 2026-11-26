# DroidKit Browser（内置浏览器）

一个极简 WebView 浏览器，用来给 Android 12 容器补上“没有浏览器”的缺口。纯 Java，
不含 native 库，x86_64 reDroid 可直接运行。

功能：

- 地址栏 + Go / 刷新，支持 `http` / `https` / `file`；
- 开启 JavaScript、DOM Storage，允许自动播放；
- 自动授予网页的摄像头/麦克风权限（`WebChromeClient.onPermissionRequest`）；
- 首页内置“测试摄像头”页面（`file:///android_asset/cam.html`），可切换后摄/前摄；
- 作为系统应用内置在镜像的 `/system/app/DroidKitBrowser/`，首次开机即可用。

## 构建

```bash
./build-apk.sh
# 输出 build/browser.apk
```

依赖：`aapt2`、`d8`、`zipalign`、`apksigner`、`android.jar`。
默认使用 `/tmp/opencode/bt33/android-13` 和
`/app/data/aosp12/prebuilts/sdk/25/public/android.jar`，可用
`BUILD_TOOLS=` / `ANDROID_JAR=` 覆盖。

## 安装到运行中的容器

```bash
adb install -r browser.apk
adb shell pm grant org.droidkit.browser android.permission.CAMERA
adb shell pm grant org.droidkit.browser android.permission.RECORD_AUDIO
adb shell am start -n org.droidkit.browser/.MainActivity
```

## 内置到镜像

`Dockerfile.android12-camera` 已经包含：

```dockerfile
COPY camera/verify/browser/browser.apk \
     /staged/system/app/DroidKitBrowser/DroidKitBrowser.apk
```

`docker/droid-kit-setup.sh` 在 `boot-complete` 阶段预授权相机/麦克风。

重新构建镜像后，新容器开机就有“浏览器”图标。

## 已知问题

WebView 的 `getUserMedia` 走 Camera2 的 `YUV_420_888` 路径，当前 HAL/gralloc
组合在这条路径上颜色异常（绿/品红），原生相机 App（RGB 预览）正常。浏览网页
不受影响；摄像头画面问题需要继续修 HAL 的 YUV 输出。
