# droid-kit

反检测 Android 容器模板（Android 13，基于 reDroid）。

镜像内置 Magisk（Delta 系 v30.7，含 Zygisk 支持）与全部反检测模块资产，首次启动自动完成安装并加载（无需重启容器）。Magisk 集成方案来自社区已验证实现 [ayasa520/redroid-script](https://github.com/ayasa520/redroid-script)。

启动流程与实测记录见 [docs/BOOT.md](docs/BOOT.md)。

## 功能

| 功能         | 方案                               |
| ------------ | ---------------------------------- |
| 机型指纹     | PlayIntegrityFork + 启动参数       |
| Root 隐藏    | Shamiko                            |
| 应用列表隐藏 | HMA-OSS（Zygisk 版，无需 LSPosed） |
| 摄像头       | ReCam                              |
| WiFi         | fake_wifi                          |
| GPS          | GPS Setter（Xposed，需 LSPosed）   |
| 传感器       | FakeSensor（Xposed，需 LSPosed）   |

## 目录结构

```text
droid-kit/
├── docker/                  # 构建资产（bootanim.rc、模块分类脚本等）
├── docs/                     # 启动流程与验证记录
├── modules/                 # 模块 zip/apk（自行下载，构建时打入镜像，不入库）
├── recam/                   # ReCam 二进制（自行下载，构建时打入镜像，不入库）
├── Dockerfile               # 多阶段构建：拉取 Magisk + 分类打入模块
├── build.sh
├── .dockerignore
└── .gitignore
```

## 准备

### 模块（放到 modules/）

| 文件                  | 类型                 | 来源                                                             |
| --------------------- | -------------------- | ---------------------------------------------------------------- |
| Shamiko.zip           | Magisk（Zygisk）     | https://github.com/LSPosed/LSPosed.github.io/releases            |
| LSPosed-zygisk.zip    | Magisk（Zygisk）     | https://github.com/LSPosed/LSPosed/releases                      |
| PlayIntegrityFork.zip | Magisk（Zygisk）     | https://github.com/osm0sis/PlayIntegrityFork/releases            |
| HMA-OSS-zygisk.zip    | Magisk（Zygisk）     | https://github.com/frknkrc44/HMA-OSS/releases                    |
| GPS-Setter.apk        | Xposed（需 LSPosed） | https://github.com/Xposed-Modules-Repo/com.android1500.gpssetter |
| FakeSensor.apk        | Xposed（需 LSPosed） | https://github.com/qilin7762-netizen/FakeSensor                  |
| fake_wifi.zip         | 待补充               | 待补充                                                           |

一键下载（已验证的版本组合，可按需换成新版本）：

```bash
cd modules/
curl -fLO https://github.com/LSPosed/LSPosed.github.io/releases/download/shamiko-414/Shamiko-v1.2.5-414-release.zip
curl -fLO https://github.com/LSPosed/LSPosed/releases/download/v1.9.2/LSPosed-v1.9.2-7024-zygisk-release.zip
curl -fLO https://github.com/osm0sis/PlayIntegrityFork/releases/download/v19/PlayIntegrityFork-v19.zip
curl -fLO https://github.com/frknkrc44/HMA-OSS/releases/download/oss-177/HMA-OSS-ZYGISK-oss-177-release.zip
curl -fL -o GPS-Setter.apk https://github.com/Xposed-Modules-Repo/com.android1500.gpssetter/releases/download/v1.2.8/app-release.apk
curl -fL -o FakeSensor.apk https://github.com/qilin7762-netizen/FakeSensor/releases/download/v1.0.0/app-debug.apk
```

> 构建脚本会自动区分两类模块：含 `module.prop` 的 zip 作为 Magisk 模块解包打入；APK 作为 Xposed 模块打入（启动时自动 `pm install`）。模块更新频繁，建议固定 release 版本。

### ReCam（放到 recam/）

从 https://github.com/aimardcr/ReCam/releases 下载对应架构的 android 包并解压（amd64 用 `android-x86_64`，arm64 用 `android-arm64`）：

```bash
cd ../   # 回到仓库根目录
curl -fLO https://github.com/aimardcr/ReCam/releases/download/v0.1.4-rc.1/recam-cli-v0.1.4-rc.1-android-x86_64.zip
unzip recam-cli-v0.1.4-rc.1-android-x86_64.zip -d recam/
```

### 宿主机

```bash
sudo modprobe binder_linux
```

## 构建

```bash
./build.sh                        # 默认 tag 13，linux/amd64
PLATFORM=linux/arm64 ./build.sh   # arm64（recam/ 需换成 arm64 版）
```

构建只产出系统资产镜像：

1. 下载 Magisk v30.7（MD5 校验）→ 按架构提取二进制
2. 模块 zip 与 Xposed APK 原样打入镜像
3. 首启在运行中的 Android 内执行 `customize.sh` 和 `pm install`

因此构建很快，不需要 binder；模块安装全部发生在容器首次启动时。

## 运行

```bash
docker run -itd --rm --privileged \
  --name droid-kit-test \
  -p 5555:5555 \
  droid-kit:13 \
  androidboot.redroid_width=1080 \
  androidboot.redroid_height=1920 \
  androidboot.redroid_dpi=480
```

> vold 启动时要求 `/data/media` 支持 POSIX ACL。脚本会在 `post-fs-data` 阶段自动给它挂一个 tmpfs，避免 Docker overlayfs（尤其是底层 ZFS 未开启 `acltype=posixacl` 时）导致用户数据目录创建失败、系统重启循环。代价是内部存储（sdcard）不持久；需要持久化时可改为 bind mount 一个 ext4/xfs 目录。

镜像只包含系统资产；首次启动会自动安装模块与 Xposed 应用，**开机即用，无需重启**。

需要持久化数据（应用、配置跨容器保留）时再挂载卷：

```bash
mkdir -p data
docker run -itd --privileged --name droid-kit \
  -v "$(pwd)/data":/data -p 5555:5555 droid-kit:13
```

注意：挂载空卷时，模块与 Xposed 应用在首启的 `post-fs-data` / `boot-complete` 阶段自动安装，同一轮启动生效，**不需要再重启容器**。复用已有数据的卷则直接开机即用。

## 首次启动

**默认（不挂数据卷）**：首启自动安装，无需任何手动步骤。

**挂载空数据卷时**，首启自动完成（约 2-3 分钟，进度日志：`docker exec droid-kit cat /data/adb/.droid-kit/boot.log`）：

1. Magisk 环境自举（优先使用 `/cache/data_adb/magisk`；该目录缺失时由 `/system/etc/init/magisk` 下的 busybox / util_functions.sh 补齐）
2. Zygisk 自动开启（仅首次；之后可在管理器里自行关闭）
3. Magisk 模块经完整安装流水线装入（含各模块自带的 customize.sh，按架构放置二进制），并交给同一轮启动的 `magisk --post-fs-data` 立即合并
4. Xposed 应用（GPS Setter / FakeSensor）、LSPosed / HMA 管理器与 Magisk 管理器自动安装

模块和 Xposed 应用都在首启内完成，**不需要 `docker restart`**。

验证：

```bash
adb connect localhost:5555
adb -s localhost:5555 shell ps -A | grep -E "lspd|zygiskd"  # lspd = LSPosed 已运行，zygiskd = Zygisk 已注入
adb -s localhost:5555 shell pm list packages -3              # 应看到 magisk / gpssetter / fakesensor / hma_oss / lsposed manager
```

GPS Setter / FakeSensor 还需在 LSPosed 管理器里启用模块并勾选作用域。

## 使用

```bash
adb connect localhost:5555
adb shell
```

ReCam 注入（镜像内路径 `/system/etc/recam`，容器内已 root）：

```bash
su
cd /system/etc/recam
./recam inject
./recam feed <视频文件或流地址>
```

## 已知问题与风险

- 通过 Play Integrity、银行类应用检测存在封号风险，请自行评估；反检测模块随目标策略调整可能随时失效
- **`/data/media` 必须支持 POSIX ACL**：vold 启动时会对它设置默认 ACL。Docker overlayfs（底层 ZFS 未开启 `acltype=posixacl` 时）会报 `Operation not supported`，表现为 `/data/user_de/0` 建不出来、`com.android.phone` 反复崩溃、系统重启循环。`droid-kit-setup` 会自动挂 tmpfs 规避；如需持久化内部存储，改为 bind mount ext4/xfs 目录
- **PlayIntegrityFork 官方 zip 仅含 ARM 库**：`linux/amd64` 容器上其 Zygisk 组件无法加载（日志报 `unloaded` / 缺 `zygisk/x86_64.so`），指纹伪装需要 `PLATFORM=linux/arm64` 构建的镜像；其余模块均自带 x86_64 库不受影响
- 构建期需联网下载 Magisk（已带校验和与重试）；网络不稳导致失败时重跑 `./build.sh` 即可
- 社区反馈：开启 Zygisk 后个别环境 adb 无法连接；多实例场景第二台容器可能启动失败
- 更新模块建议直接替换 `modules/` 内文件并重新构建镜像，比在管理器内升级更可控
