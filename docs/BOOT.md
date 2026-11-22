# 启动流程与验证

本文说明 `droid-kit` 的启动流程、模块加载方式，以及在当前环境下的实测结果。

## 设计目标

- 镜像只包含系统资产（Magisk 二进制、模块 zip、Xposed APK、ReCam）；Android 12 相机 HAL/provider 通过 `camera/android12/` 单独构建
- 首次启动自动完成全部安装、默认启用并写入作用域，**不需要重启容器**（LSPosed 启动后 system_server 会软重启一次）
- Zygisk 保留 reDroid 的 native bridge（ARM 转译）能力
- 不依赖宿主机 `/data` 支持 POSIX ACL

## 启动时序

```text
init
└─ post-fs-data
   ├─ /system/bin/droid-kit-setup post-fs-data
   │  ├─ 必要时 bind mount /data（让 Magisk 的 check_data 通过）
   │  ├─ mount tmpfs /data/media（vold 需要 POSIX ACL）
   │  ├─ 自举 /data/adb/magisk（busybox + util_functions.sh）
   │  ├─ 首次启动写入 zygisk=1
   │  └─ 安装模块 zip（BOOTMODE=true, ZYGISK_ENABLED=1）
   │     └─ 写入 /data/adb/modules_update/<id>
   └─ /sbin/magisk --post-fs-data
      ├─ upgrade_modules：modules_update → modules
      ├─ 执行模块 post-fs-data.sh
      ├─ 配置 Zygisk 与 native bridge 别名
      └─ zygote / system_server 启动（Zygisk 注入）
└─ late-start
   ├─ /system/bin/droid-kit-setup late-start
   │  ├─ 等 sys.boot_completed=1
   │  ├─ 安装全部 10 个 Xposed 模块
   │  └─ 写入 LSPosed 默认启用与作用域（静态 sqlrun）
   └─ /sbin/magisk --service
      └─ LSPosed service.sh → lspd（读取上面的配置）
└─ boot-complete（每轮启动只执行一次）
   ├─ 安装 LSPosed / HMA 管理器
   ├─ 补装 Magisk 管理器
   └─ 写入 boot.log: boot-complete done
```

关键点：Magisk 模块安装发生在 `/sbin/magisk --post-fs-data` **之前**，在同一轮启动中完成合并并由 Zygisk 加载。Xposed 应用在 `late-start` 安装，LSPosed 配置在 `lspd` 启动前写入，因此首次启动就处于默认启用/作用域状态。

## 为什么不需要重启

模块安装使用 `BOOTMODE=true`：

- 模块按“已启动系统”路径安装（LSPosed 会拒绝 recovery 模式）
- 模块文件写入 `modules_update`
- 紧随其后的 `magisk --post-fs-data` 完成合并
- zygote 在合并之后启动，Zygisk 直接加载模块

Xposed APK 在 `late-start` 安装；LSPosed 的默认启用与作用域写入 `modules_config.db` 后，`service.sh` 才启动 `lspd`，因此不存在“装完还要手动开模块”的步骤。

LSPosed 启动时会对已运行的 system_server 做一次注入，导致 system_server 软重启一次；`boot-complete` 用每轮标记避免重复执行。容器本身只启动一次。

## Native bridge 与 Zygisk

reDroid 镜像声明：

```text
ro.dalvik.vm.native.bridge=libnb.so
```

镜像内实际提供：

```text
/system/lib/libnb.so   -> libndk_translation.so
/system/lib64/libnb.so -> libndk_translation.so
/system/lib64/libndk_translation.so
```

Magisk 会把属性改写为 `libzygisk.so` + 原始库名，并在 worker 挂载中注入对应别名，由 Zygisk 的 hook 还原并加载原始 native bridge。

本方案**不重置** native bridge 属性。Zygisk 运行后属性会被改写为：

```text
getprop ro.dalvik.vm.native.bridge
libzygisk.solibnb.so
```

worker 中对应的加载器别名指向 Magisk，原始库保留并由 hook 加载：

```text
/sbin/.magisk/worker/system/lib64/libzygisk.solibnb.so  (bind mount, source /sbin/magisk)
/sbin/.magisk/worker/system/lib64/libnb.so -> libndk_translation.so
```

`zygiskd64`、`lspd` 均正常运行。

## Zygisk 稳定性（Magisk v31.1）

旧版 Magisk v30.7 的 `zygisk/hook.cpp` 缺少 `jni_hooked` 保护。lazy native bridge 设备上，`post_native_bridge_load` 与 `strdup("ZygoteInit")` 两条路径都会触发 JNI hook，第二次会破坏 JNI 注册，表现为：

```text
JNI DETECTED ERROR ... buffer capacity greater than maximum jint
in call to NewDirectByteBuffer
from Zygote.nativeForkSystemServer
```

随后 zygote 连续崩溃，Magisk 回滚 Zygisk。该问题与模块无关，与 `/data` 也无关。

Magisk v31.1 已包含 `jni_hooked` 保护。本镜像使用 v31.1，连续两次启动（首启 + 容器重启）实测 `JNI` 错误均为 `0`。

## `/data/media` 与 ACL

Android 13 的 vold 在用户解锁时会对 `/data/media/0` 设置 default ACL。Docker overlayfs（尤其是 ZFS 未开启 `acltype=posixacl`）不支持该操作，会导致：

```text
vold: Failed to set default ACL on /data/media/0: Operation not supported
→ prepareUserStorage 失败
→ /data/user_de/0 建不出来
→ com.android.phone 反复崩溃
```

`droid-kit-setup` 在 `post-fs-data` 阶段（system_server 启动前）执行：

```sh
mount -t tmpfs -o size=2g,mode=0771 tmpfs /data/media
```

因此不需要宿主机 ACL 卷。

代价：内部存储（sdcard）在容器重启后清空。需要持久化时，可把这一步替换为 bind mount 一个 ext4/xfs 目录。

## 构建与运行

```bash
./build.sh                        # 默认 tag 13，linux/amd64
PLATFORM=linux/arm64 ./build.sh   # arm64
```

`build.sh` 先下载 Magisk v31.1 到 `docker/` 并校验 MD5，然后执行 `docker buildx build`；不需要 binder、不需要 prime 容器。

运行：

```bash
docker run -itd --rm --privileged \
  --name droid-kit-test \
  -p 5555:5555 \
  droid-kit:13 \
  androidboot.redroid_width=1080 \
  androidboot.redroid_height=1920 \
  androidboot.redroid_dpi=480
```

## 实测结果

测试环境：

- 镜像：`droid-kit:13`（linux/amd64）
- 启动方式：不挂数据卷
- 宿主机 Docker 后端：ZFS（未开启 POSIX ACL）

首启约 200 秒到达 `boot-complete done`；随后执行一次 `docker restart`，第二次约 120 秒到达。每轮 `boot-complete` 只执行一次（system_server 软重启后的重复触发被标记跳过），未出现 Zygisk 回滚。

### 启动日志（首启摘要）

```text
11-22 08:22:35 lsposed configured: 10 module(s)
11-22 08:22:37 === droid-kit-setup boot-complete (pid 5926) ===
11-22 08:23:06 manager installed: /data/adb/modules/hma_oss_zygisk/manager.apk
11-22 08:23:32 battery spoof applied
11-22 08:23:32 === boot-complete done ===
11-22 08:24:15 === droid-kit-setup boot-complete (pid 7237) ===
11-22 08:24:52 manager reinstalled (post-restart)
11-22 08:24:53 battery spoof applied
11-22 08:24:53 === boot-complete already done (system_server restart) ===
```

第二次容器启动后 `grep -c 'boot-complete done'` = `2`；每轮只增加一次，没有 boot-complete 循环。

### 模块

Magisk：

```text
hma_oss_zygisk
playintegrityfix
xj_bluejay
zygisk_lsposed
zygisk_shamiko
```

Xposed：10 个模块全部写入 LSPosed DB，`enabled=1`，每个 83 个作用域：

```text
com.android1500.gpssetter
com.app.fakesensor
com.waydroid.networkspoof
io.github.imkamaran.hidemydevice
com.brianwalczak.telephonyspoofer
com.android1500.androidfaker
com.devicespooflab.hooks
com.sal.privacykit
com.sal.privacykit.lite
com.spoofmydevice
```

### 进程

```text
system  2157    1 ... lspd
system  3049 2937 ... system_server
root    3056    1 ... zygiskd64
```

### 应用

```text
com.app.fakesensor
io.github.imkamaran.hidemydevice
com.brianwalczak.telephonyspoofer
com.devicespooflab.hooks
com.android1500.androidfaker
com.android1500.gpssetter
com.sal.privacykit.lite
com.topjohnwu.magisk
com.spoofmydevice
com.sal.privacykit
org.frknkrc44.hma_oss
com.waydroid.networkspoof
org.lsposed.manager
```

### 关键属性与预置值

```text
ro.product.brand      = google
ro.product.model      = GB62Z
ro.product.marketname = Pixel 6a
battery level         = 87
battery status        = 2 (charging)
battery AC            = true
battery temperature   = 305 (30.5°C)
```

Hide My Device / TelephonySpoofer 的 SharedPreferences 同时写入：

```text
/data/user/0/<pkg>/shared_prefs/*.xml
/data/data/<pkg>/shared_prefs/*.xml
/data/misc/<uuid>/prefs/<pkg>/*.xml
```

### 错误计数

```text
Failed to set default ACL: 0
Zygote JNI buffer capacity 错误: 0
system_server 崩溃: 0
com.android.phone FATAL: 0
```

### 已知噪声

- `android.hardware.bluetooth@1.1-service.sim` / `com.android.bluetooth` 反复崩溃
- 偶发单个 `com.android.statementservice` FATAL
- LSPosed 在 late-start 启动后 system_server 软重启一次；boot-complete 用每轮标记跳过重复执行

## 兼容/兜底代码审计

### 已移除

- **构建期 prime/commit**：不再启动临时 Android 并把 `/data` 固化进镜像
- **prepare-modules.sh 的宽松匹配**：
  - 子目录内查找 `module.prop` / `AndroidManifest.xml`
  - 大写 `.APK` / `.ZIP` 扩展名
  - 把带 `AndroidManifest.xml` 的 zip 当作 Xposed 模块
- **运行时不再重置 native bridge 属性**：保留 `libnb.so` 与 ARM 转译链路
- **bootanim.rc 冗余触发**：
  - 三个重复的 `magiskpolicy --live --magisk` 上下文（SELinux 为 Disabled，且均会 FORTIFY 崩溃）
  - `vold.decrypt=trigger_restart_framework` 分支（reDroid 为 unencrypted，实际只触发 `nonencrypted`）
  - `init.svc.zygote=stopped` 分支（实际只触发 `init.svc.zygote=restarting`）

### 保留（必要依赖，不是兼容分支）

| 代码 | 原因 |
| --- | --- |
| `mount --bind /data /data` | Magisk 的 `check_data` 要求 `/data` 出现在挂载表 |
| `mount tmpfs /data/media` | vold 设置 default ACL 所需 |
| `/data/adb/magisk` 自举 | 模块安装早于 Magisk 的 `post-fs-data` |
| `BOOTMODE=true` / `ZYGISK_ENABLED=1` / `PATH` | 模块安装脚本的语义与命令查找 |
| `.droid-kit` marker | 首启安装幂等，避免重复执行 |
| `sleep 20` / `sleep 25` | 等系统服务就绪、等 Magisk 管理器签名卸载后补装 |
| `pm install -r` | 幂等安装 |
| `/cache/data_adb` + `/system` 两份 util_functions.sh | 前者供 Magisk 自身环境导入，后者供更早的模块安装阶段使用 |
| `bootanim.rc` 的 `nonencrypted` + `zygote=restarting` 触发器 | redroid 实际触发的 Magisk 服务与 Zygisk 重启入口 |
| `bootanim.rc.gz` | Magisk 管理器自更新时还原触发配置 |
| `build.sh` 的 `curl --http1.1 --retry` | 宿主机下载 Magisk 的网络健壮性 |
| `PLATFORM` / `TARGETARCH` | amd64 / arm64 多架构支持 |
| `docker/sqlrun` + LSPosed DB 写入 | Android 自带 `sqlite3` 因 ICU 数据 abort；静态工具用于默认启用/作用域 |
| LSPosed `post-fs-data.sh` 去除 daemon 启动 | 让 lspd 在 late-start 写入配置后启动，否则启动缓存会读到空配置 |
| `boot-complete-done` 每轮标记 | system_server 软重启会再次触发 boot-complete，标记避免重复安装管理器 |

### 已升级

- Magisk v30.7 → v31.1：修复 Zygisk lazy native bridge 二次 hook 导致的 JNI 注册损坏
- PlayIntegrityFork v19（ARM-only）→ PlayIntegrityFix v4.9-inject-s（含 x86_64）

## 已加入的模块

| 方向 | 模块 |
| --- | --- |
| 设备标识 | Hide My Device、AndroidFaker |
| SIM / 运营商 | TelephonySpoofer、Hide My Device |
| 机型 / Build | Magisk-DeviceSpoofer Pixel 6a、PlayIntegrityFix v4.9、DeviceSpoofLab、SpoofMyDevice |
| 隐私 / ID | PrivacyKit、PrivacyKitLite |
| Root / 应用列表 | Shamiko、HMA-OSS |
| WiFi / 网络 | Waydroid Network Spoof、TelephonySpoofer |
| GPS / 传感器 | GPS Setter、FakeSensor |
| 摄像头 | ReCam（需已有相机）；Android 12 V4L2 方案见 `docs/CAMERA-ANDROID12.md` |
| 电池 | `dumpsys battery set` 启动写入 |

这些模块都和普通模块一样安装、在 LSPosed 中启用并写入作用域。各模块自身的配置需求：

- Hide My Device / TelephonySpoofer / Magisk-DeviceSpoofer：已预置默认值
- SpoofMyDevice / DeviceSpoofLab / PrivacyKit：需要在其 app 内分配 profile 或开启对应开关
- AndroidFaker：使用其默认/全局值
- PrivacyKit / PrivacyKitLite 声明 API 102，LSPosed 1.9.2 可能拒绝注入；模块仍安装并启用（不做额外兼容/降级）

## 已知限制

- **PlayIntegrityFix v4.9 已带 x86_64 库**：amd64 可加载；但 A13+ DEVICE 需要硬件 keybox，reDroid 无 TEE，默认只能到 BASIC
- `/data/media` 使用 tmpfs，sdcard 数据不持久
- 测试镜像默认关闭 adb 认证（`ro.adb.secure=0`），正式环境应恢复认证或写入自己的 adb key
- 10 个 Xposed 模块默认启用并写入作用域；作用域排除 `android` / `system` / GMS / Play Store / SystemUI
- 新安装的应用在下次容器启动时自动加入作用域；不重启时可在 LSPosed 管理器手动勾选
- LSPosed 首次启动会让 system_server 软重启一次；`boot-complete` 只执行一次，容器本身只启动一次
- 首次启动约 3 分钟完成模块、Xposed 和 LSPosed 配置
- SpoofMyDevice / DeviceSpoofLab / PrivacyKit 需要自身 app 内配置；PrivacyKit/PrivacyKitLite 的 API 102 与 LSPosed 1.9.2 不匹配时可能不生效
