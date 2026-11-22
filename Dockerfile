# syntax=docker/dockerfile:1

# 反检测 Android 容器：reDroid 13 + Magisk（Zygisk）+ 预置模块。
# Magisk 集成方案基于 ayasa520/redroid-script 的已验证实现：
#   https://github.com/ayasa520/redroid-script
# 用户需提前把模块 zip 放到 modules/、ReCam 二进制放到 recam/（见 README）。

ARG REDROID_IMAGE=docker.io/redroid/redroid:13.0.0-latest@sha256:41e5f0c1ff27a4a474c474e5595168cedf6c40fc5dd102c5617f48c80f511e9e

FROM ${REDROID_IMAGE} AS redroid

# ---------------------------------------------------------------- 打包阶段
FROM debian:bookworm-slim AS prep

ARG TARGETARCH
ARG MAGISK_APK_URL=https://github.com/ayasa520/Magisk/releases/download/v30.7/Magisk-v30.7.apk
ARG MAGISK_APK_MD5=0a31050fdcfaa15f47c9dd1eb8d04fc8

RUN apt-get update \
 && apt-get install -y --no-install-recommends curl ca-certificates libarchive-tools gzip \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /build

# 下载 Magisk（Delta 系分支）并校验
# curl 参数：强制 HTTP/1.1 规避 HTTP/2 PROTOCOL_ERROR；限速超时防挂死；失败自动重试
RUN curl -fsSL --http1.1 --retry 8 --retry-all-errors --retry-delay 2 \
      --connect-timeout 20 --speed-limit 1024 --speed-time 30 \
      -o magisk.apk "${MAGISK_APK_URL}" \
 && echo "${MAGISK_APK_MD5}  magisk.apk" | md5sum -c - \
 && mkdir unpack && bsdtar -xf magisk.apk -C unpack

# 从 APK 提取当前架构的 Magisk 二进制（lib*.so → 去掉前缀后缀）
RUN case "${TARGETARCH}" in \
      arm64) abi=arm64-v8a ;; \
      amd64) abi=x86_64 ;; \
      *) echo "unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \
    esac \
 && mkdir -p /staged/system/etc/init/magisk /staged/sbin \
 && for f in unpack/lib/"${abi}"/lib*.so; do \
      n=$(basename "${f}"); n=${n#lib}; n=${n%.so}; \
      cp "${f}" "/staged/system/etc/init/magisk/${n}"; \
      chmod 0755 "/staged/system/etc/init/magisk/${n}"; \
    done \
 && cp magisk.apk /staged/system/etc/init/magisk/magisk.apk

# Magisk 运行环境：setup_magisk_env 在首次 post-fs-data 时会从 /cache/data_adb/magisk
# 自动导入到 /data/adb/magisk（busybox + util_functions.sh），补齐容器场景的安装步骤。
# 同一份 util_functions.sh 也放到 /system/etc/init/magisk/，供 droid-kit-setup 在
# 全新数据卷上自举（/cache 在首次启动后可能不可用）。
RUN bsdtar -xf magisk.apk -C unpack assets/util_functions.sh \
 && mkdir -p /staged/cache/data_adb/magisk \
 && cp unpack/assets/util_functions.sh /staged/cache/data_adb/magisk/util_functions.sh \
 && cp unpack/assets/util_functions.sh /staged/system/etc/init/magisk/util_functions.sh \
 && cp /staged/system/etc/init/magisk/busybox /staged/cache/data_adb/magisk/busybox \
 && chmod 0755 /staged/cache/data_adb/magisk/busybox

# bootanim.rc：原服务定义 + Magisk 触发器；gz 备份供 Magisk 管理器自更新时还原
COPY docker/bootanim.rc docker/bootanim-original.rc /staged/system/etc/init/
RUN gzip -9 -c /staged/system/etc/init/bootanim-original.rc > /staged/system/etc/init/bootanim.rc.gz \
 && rm /staged/system/etc/init/bootanim-original.rc

COPY docker/droid-kit-setup.sh /staged/system/bin/droid-kit-setup
RUN chmod 0755 /staged/system/bin/droid-kit-setup

# 预置模块：Magisk 模块解包到 magisk-preload/，Xposed 模块原样放到 xposed-modules/
COPY docker/prepare-modules.sh /tmp/prepare-modules.sh
COPY modules/ /tmp/modules/
RUN sh /tmp/prepare-modules.sh /tmp/modules /staged

# ReCam 二进制
COPY recam/ /staged/system/etc/recam/
RUN chmod 0755 /staged/system/etc/recam/recam

# ---------------------------------------------------------------- 最终镜像
FROM redroid

COPY --from=prep /staged/ /

LABEL org.opencontainers.image.title="droid-kit" \
      org.opencontainers.image.description="Android 13 container image based on reDroid, with Magisk (Zygisk) and anti-detection modules preloaded" \
      org.opencontainers.image.source="https://github.com/wangsendi/droid-kit"
