# AOSP 12 build environment for the legacy camera.v4l2 HAL.
# Ubuntu 20.04 matches the toolchain expectations of android-12.0.0_r34.
FROM ubuntu:20.04

ENV DEBIAN_FRONTEND=noninteractive
ENV LC_ALL=C
ENV JAVA_HOME=/usr/lib/jvm/java-11-openjdk-amd64

# Use a faster mirror for focal; the default archive is very slow from this host.
RUN sed -i 's|http://archive.ubuntu.com/ubuntu|http://mirrors.ustc.edu.cn/ubuntu|g; s|http://security.ubuntu.com/ubuntu|http://mirrors.ustc.edu.cn/ubuntu|g' /etc/apt/sources.list

RUN apt-get update && apt-get install -y --no-install-recommends \
    openjdk-11-jdk \
    python3 python3-pip python-is-python3 \
    git curl ca-certificates \
    bc bison build-essential ccache flex g++-multilib gcc-multilib \
    gnupg gperf imagemagick lib32ncurses5-dev lib32readline-dev lib32z1-dev \
    libelf-dev liblz4-tool libncurses5 libncurses5-dev libsdl1.2-dev \
    libc6-dev-i386 x11proto-core-dev libx11-dev libgl1-mesa-dev fontconfig \
    libssl-dev libxml2 libxml2-utils lzop pngcrush rsync schedtool \
    squashfs-tools xsltproc zip zlib1g-dev \
    file unzip wget cpio \
  && rm -rf /var/lib/apt/lists/*

# ccache keeps incremental module rebuilds fast.
ENV USE_CCACHE=1
ENV CCACHE_DIR=/aosp/.ccache

WORKDIR /aosp
