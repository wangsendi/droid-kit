#!/system/bin/sh
# droid-kit 首次启动辅助脚本，由 bootanim.rc 调用。
# 用法：droid-kit-setup {post-fs-data|boot-complete}
#
# post-fs-data ：保证 /data 在挂载表中、自举 Magisk 运行环境、预开启 Zygisk，
#                 并在 /sbin/magisk --post-fs-data 之前安装镜像内置的 Magisk 模块。
#                 Magisk 会在同一轮启动中把 modules_update 合并进 modules，
#                 模块随后由 Zygisk 加载——不需要重启容器。
# boot-complete ：安装 Xposed 应用、各模块自带的管理器，补装 Magisk 管理器。
#
# 运行日志：/data/adb/.droid-kit/boot.log

MODULE_ZIPS="/system/etc/module-zips"
XPOSED="/system/etc/xposed-modules"
MAGISKBIN="/data/adb/magisk"
MARKERS="/data/adb/.droid-kit"
LOG="${MARKERS}/boot.log"

mkdir -p "${MARKERS}" 2>/dev/null
log() { echo "$(date '+%m-%d %H:%M:%S') $*" >>"${LOG}" 2>/dev/null; }

stage="$1"
log "=== droid-kit-setup ${stage} (pid $$) ==="

case "$stage" in
post-fs-data)
    # 无卷启动时 /data 不在 /proc/mounts，magisk 会静默跳过 post-fs-data 回调。
    # 自绑定挂载让它出现在挂载表（挂数据卷时已有条目，grep 不中、跳过）。
    if ! grep -q " /data " /proc/mounts 2>/dev/null; then
        mount --bind /data /data && log "/data bind-mounted"
    fi

    # /data 由 init 挂载后会覆盖容器启动时的 --tmpfs，而 vold 在用户解锁时
    # 需要 /data/media 支持 POSIX ACL。这里在 system_server 启动前补挂 tmpfs。
    if ! grep -q " /data/media tmpfs " /proc/mounts 2>/dev/null; then
        mkdir -p /data/media
        mount -t tmpfs -o size=2g,mode=0771 tmpfs /data/media \
            && log "tmpfs mounted on /data/media"
    fi

    # 自举 Magisk 运行环境：全新数据卷上 /data/adb/magisk 为空，
    # magisk --install-module 会报 "Incomplete Magisk install"。
    if [ ! -x "${MAGISKBIN}/busybox" ] || [ ! -f "${MAGISKBIN}/util_functions.sh" ]; then
        mkdir -p "${MAGISKBIN}"
        cp /system/etc/init/magisk/busybox "${MAGISKBIN}/busybox" 2>/dev/null \
            && chmod 0755 "${MAGISKBIN}/busybox"
        cp /system/etc/init/magisk/util_functions.sh "${MAGISKBIN}/util_functions.sh" 2>/dev/null
        log "magisk env bootstrapped"
    fi

    # 确保 magiskd 已就绪（--setup-sbin 通常已经拉起，这里兜底）
    /sbin/magisk --daemon >/dev/null 2>&1

    # 预开启 Zygisk（仅首启）
    if [ ! -e "${MARKERS}/zygisk-on" ]; then
        /sbin/magisk --sqlite "REPLACE INTO settings (key,value) VALUES('zygisk',1)" >/dev/null 2>&1 \
            && touch "${MARKERS}/zygisk-on" && log "zygisk enabled"
    fi

    # Magisk 模块必须在 /sbin/magisk --post-fs-data 之前安装：
    # 该回调会先 upgrade_modules() 把 modules_update 合并进 modules，再执行
    # 模块脚本、加载 Zygisk 模块，随后 zygote 才启动。
    # BOOTMODE=true：按“已启动系统”安装（LSPosed 拒绝 recovery 模式），
    # 同时让 MODPATH 指向 modules_update，交给同一轮启动的合并流程。
    # ZYGISK_ENABLED=1：内置 Zygisk 此刻还没被标记为已启用，但设置已经写入；
    # 显式告知安装脚本（HMA-OSS 会检查这个变量）。
    export BOOTMODE=true ZYGISK_ENABLED=1
    export PATH="/sbin:${PATH}"
    mkdir -p "${MARKERS}/modules"
    for z in "${MODULE_ZIPS}"/*; do
        [ -f "$z" ] || continue
        b="$(basename "$z")"
        [ -e "${MARKERS}/modules/$b" ] && continue
        log "magisk module install: $b"
        if /sbin/magisk --install-module "$z" >>"$LOG" 2>&1; then
            touch "${MARKERS}/modules/$b"
            log "magisk module installed: $b"
        else
            log "magisk module FAILED: $b"
        fi
    done
    ;;

boot-complete)
    sleep 20
    mkdir -p "${MARKERS}/xposed" "${MARKERS}/managers"

    # Xposed 应用
    for f in "${XPOSED}"/*; do
        [ -f "$f" ] || continue
        b="$(basename "$f")"
        [ -e "${MARKERS}/xposed/$b" ] && continue
        log "xposed install: $b"
        pm install -r "$f" >/dev/null 2>&1 \
            && touch "${MARKERS}/xposed/$b" && log "xposed installed: $b"
    done

    # 模块自带的管理器 APK：它们在 post-fs-data 阶段调用 pm 会失败，
    # 这里等系统起来后统一补装。
    for apk in /data/adb/modules/zygisk_lsposed/manager.apk \
               /data/adb/modules/hma_oss_zygisk/manager.apk; do
        [ -f "$apk" ] || continue
        b="$(echo "$apk" | sed 's#/#_#g')"
        [ -e "${MARKERS}/managers/$b" ] && continue
        log "manager install: $apk"
        pm install -r "$apk" >/dev/null 2>&1 \
            && touch "${MARKERS}/managers/$b" && log "manager installed: $apk"
    done

    # Magisk 管理器：本 fork 每次开机 boot-complete 后约 20-30 秒会以"签名不符"
    # 卸载管理器。等卸载发生，随后补装一次。
    sleep 25
    if ! pm path com.topjohnwu.magisk >/dev/null 2>&1; then
        pm install /system/etc/init/magisk/magisk.apk >/dev/null 2>&1 \
            && log "manager reinstalled"
    fi
    log "=== boot-complete done ==="
    ;;
esac

exit 0