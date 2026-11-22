# 启动流程与验证

本文说明 `droid-kit` 的启动流程、模块加载方式，以及在当前环境下的实测结果。

## 设计目标

- 镜像只包含系统资产（Magisk 二进制、模块 zip、Xposed APK、ReCam）
- 首次启动自动完成全部安装，**不需要重启容器**
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
      └─ zygote 启动（Zygisk 注入）
└─ boot-complete
   └─ /system/bin/droid-kit-setup boot-complete
      ├─ 安装 GPS Setter / FakeSensor
      ├─ 安装 LSPosed / HMA 管理器
      ├─ 补装 Magisk 管理器
      └─ 写入 boot.log: boot-complete done
```

关键点：模块安装发生在 `/sbin/magisk --post-fs-data` **之前**。Magisk 会在同一轮启动中把 `modules_update` 合并进 `modules`，随后 zygote 才启动，因此 Zygisk 和模块在首次启动就生效。

## 为什么不需要重启

模块安装使用 `BOOTMODE=true`：

- 模块按“已启动系统”路径安装（LSPosed 会拒绝 recovery 模式）
- 模块文件写入 `modules_update`
- 紧随其后的 `magisk --post-fs-data` 完成合并
- zygote 在合并之后启动，Zygisk 直接加载模块

Xposed APK 在 `boot-complete` 安装，属于普通应用安装，不需要重启容器。

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

本方案**不重置** native bridge 属性，首次启动后实测：

```text
getprop ro.dalvik.vm.native.bridge
libnb.so
```

且 `zygiskd64`、`lspd` 均正常运行。

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

构建只执行 `docker buildx build`，不需要 binder、不需要 prime 容器。

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

启动耗时约 130 秒到达 `boot-complete done`，之后未进行任何重启。

### 启动日志

```text
11-22 04:08:26 === droid-kit-setup boot-complete (pid 3701) ===
11-22 04:08:46 xposed install: FakeSensor.apk
11-22 04:08:47 xposed installed: FakeSensor.apk
11-22 04:08:47 xposed install: GPS-Setter.apk
11-22 04:08:51 xposed installed: GPS-Setter.apk
11-22 04:08:51 manager install: /data/adb/modules/zygisk_lsposed/manager.apk
11-22 04:08:54 manager installed: /data/adb/modules/zygisk_lsposed/manager.apk
11-22 04:08:54 manager install: /data/adb/modules/hma_oss_zygisk/manager.apk
11-22 04:08:56 manager installed: /data/adb/modules/hma_oss_zygisk/manager.apk
11-22 04:09:26 manager reinstalled
11-22 04:09:26 === boot-complete done ===
```

`grep -c 'boot-complete done'` 结果为 `1`，30 秒后仍为 `1`（没有重启循环）。

### 模块

```text
hma_oss_zygisk: 9 files
playintegrityfix: 12 files
zygisk_lsposed: 10 files
zygisk_shamiko: 7 files
```

### 进程

```text
root   110  1 ... magiskd
system 1310 1 ... lspd
system 1608 1445 ... system_server
root   1615 1 ... zygiskd64
```

### 应用

```text
package:com.app.fakesensor
package:com.android1500.gpssetter
package:com.topjohnwu.magisk
package:org.frknkrc44.hma_oss
package:org.lsposed.manager
```

### 关键属性与挂载

```text
ro.dalvik.vm.native.bridge = libnb.so
key=zygisk|value=1
key=bootloop|value=0
tmpfs /data/media tmpfs rw,relatime,size=2097152k,mode=771,inode64 0 0
```

### 错误计数

```text
Failed to set default ACL: 0
Zygote JNI buffer capacity 错误: 0
/system/bin/sh: ...（无）
```

- `com.android.phone` / `system_server` 无崩溃
- `/data/user_de/0/com.android.providers.telephony/databases` 正常存在

### 已知噪声

以下日志不影响启动和使用，属于 reDroid 基础镜像或硬件模拟服务：

- `magiskpolicy` 启动时 `FORTIFY: fread: null FILE*`（SIGABRT）
- `android.hardware.bluetooth@1.1-service.sim` / `com.android.bluetooth` 反复崩溃
- 偶发单个 `com.android.statementservice` FATAL

## 已知限制

- **PlayIntegrityFork 官方 zip 仅含 ARM 库**：`linux/amd64` 镜像上其 Zygisk 组件无法加载，需要 `PLATFORM=linux/arm64`
- `/data/media` 使用 tmpfs，sdcard 数据不持久
- GPS Setter / FakeSensor 安装后仍需在 LSPosed 管理器里启用模块并勾选作用域
- 首次启动需要约 2-3 分钟完成模块和 Xposed 安装