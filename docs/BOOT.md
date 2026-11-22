# 启动流程与验证

本文说明 `droid-kit` 的启动流程、模块加载方式，以及在当前环境下的实测结果。

## 设计目标

- 镜像只包含系统资产（Magisk 二进制、模块 zip、Xposed APK、ReCam）
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
   │  ├─ 安装 GPS Setter / FakeSensor / Waydroid Network Spoof
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

首启约 160 秒到达 `boot-complete done`；随后执行一次 `docker restart`，第二次约 120 秒到达。每轮 `boot-complete` 只执行一次（system_server 软重启后的重复触发被标记跳过），未出现 Zygisk 回滚。

### 启动日志

```text
11-22 07:01:32 === droid-kit-setup late-start (pid 1464) ===
11-22 07:02:32 xposed installed: FakeSensor.apk
11-22 07:02:39 xposed installed: GPS-Setter.apk
11-22 07:02:41 xposed installed: WaydroidNetworkSpoof.apk
11-22 07:02:44 lsposed configured (late-start)
11-22 07:03:08 manager install: /data/adb/modules/zygisk_lsposed/manager.apk
11-22 07:03:12 manager installed: /data/adb/modules/zygisk_lsposed/manager.apk
11-22 07:03:12 manager install: /data/adb/modules/hma_oss_zygisk/manager.apk
11-22 07:03:15 manager installed: /data/adb/modules/hma_oss_zygisk/manager.apk
11-22 07:03:45 manager reinstalled
11-22 07:03:45 === boot-complete done ===
11-22 07:04:42 === boot-complete already done (system_server restart) ===
```

`grep -c 'boot-complete done'` 首启后为 `1`，第二次容器启动后为 `2`；每轮只增加一次，没有 boot-complete 循环。

### 模块

```text
hma_oss_zygisk: 9 files
playintegrityfix: 12 files
zygisk_lsposed: 10 files
zygisk_shamiko: 7 files
```

### 进程

```text
root      85    1 ... magiskd
system  1701    1 ... lspd
system  2521 2392 ... system_server
root    2528    1 ... zygiskd64
```

### 应用

```text
package:com.app.fakesensor
package:com.android1500.gpssetter
package:com.topjohnwu.magisk
package:org.frknkrc44.hma_oss
package:com.waydroid.networkspoof
package:org.lsposed.manager
```

### 关键属性与挂载

```text
ro.dalvik.vm.native.bridge = libzygisk.solibnb.so
key=zygisk|value=1
key=bootloop|value=0
tmpfs /data/media tmpfs rw,relatime,size=2097152k,mode=771,inode64 0 0
```

LSPosed 默认配置（每个模块 84 个作用域）：

```text
com.android1500.gpssetter | enabled=1
com.app.fakesensor         | enabled=1
com.waydroid.networkspoof  | enabled=1
scope 排除 android / system
```

`com.android.settings` 新进程日志：

```text
LSPosed-Bridge: NetworkSpoofer: Loaded for com.android.settings — wifi=true cellular=true
```

### 错误计数

```text
Failed to set default ACL: 0
Zygote JNI buffer capacity 错误: 0
magiskpolicy 崩溃: 0
system_server 崩溃: 0
com.android.phone FATAL: 0
```

- `com.android.phone` 无崩溃；system_server 仅因 LSPosed 注入软重启一次
- `/data/user_de/0/com.android.providers.telephony/databases` 正常存在

### 已知噪声

以下日志不影响启动和使用，属于 reDroid 基础镜像或硬件模拟服务：

- `android.hardware.bluetooth@1.1-service.sim` / `com.android.bluetooth` 反复崩溃
- 偶发单个 `com.android.statementservice` FATAL
- LSPosed 在 `late-start` 启动后，system_server 会软重启一次；`boot-complete` 通过每轮标记跳过重复执行

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

## 可加入的真机化模块（建议）

当前已覆盖：机型指纹（PIF）、Root 隐藏（Shamiko）、应用列表隐藏（HMA）、WiFi（Waydroid Network Spoof）、GPS、传感器、摄像头（ReCam）。

还可考虑：

| 方向 | 候选 | 说明/风险 |
| --- | --- | --- |
| 设备 ID | Android Faker / Device ID Masker（LSPosed） | Android ID、IMEI、序列号、MAC；需先验证 Android 13 兼容性，可能和 PIF/HMA 冲突 |
| SIM/运营商 | Fake SIM / SIM Operator（LSPosed） | 运营商、MCC/MNC；需验证 Android 13 |
| Play Integrity | 新版 PIF / Tricky Store（Magisk） | amd64 上 PIF 仅 ARM 库；Tricky Store 需要 keybox，风险高，不建议默认加入 |
| Root 隐藏 | Zygisk Assistant（Magisk） | 与 Shamiko 功能重叠，可能冲突；默认不加 |
| 系统属性 | Sensitive Props / device props | PIF 已覆盖大部分指纹；额外模块可能干扰 OTA/系统属性 |
| 电量/充电 | Battery Spoofer（Xposed） | 影响面较小，优先级低 |
| 电池/温度 | 各类 Sensor Spoof | FakeSensor 已覆盖部分传感器 |
| 网络 | Waydroid Network Spoof | 已加入并默认启用 |
| 相机 | ReCam | 已内置二进制，需按 README 注入 |

建议优先级：**设备 ID > SIM/运营商 > Play Integrity（arm64/新版 PIF）**。涉及 keybox、IMEI 的模块有封号和合规风险，默认不打包。

## 已知限制

- **PlayIntegrityFork 官方 zip 仅含 ARM 库**：`linux/amd64` 镜像上其 Zygisk 组件无法加载，需要 `PLATFORM=linux/arm64`
- `/data/media` 使用 tmpfs，sdcard 数据不持久
- GPS Setter / FakeSensor / Waydroid Network Spoof 默认已启用并写入作用域；作用域排除 `android` / `system`
- 新安装的应用在下次容器启动时自动加入作用域；不重启时可在 LSPosed 管理器手动勾选
- LSPosed 首次启动会让 system_server 软重启一次；`boot-complete` 只执行一次，容器本身只启动一次
- 首次启动约 3 分钟完成模块、Xposed 和 LSPosed 配置