#!/system/bin/sh
# droid-kit 首次启动辅助脚本，由 bootanim.rc 调用。
# 用法：droid-kit-setup {post-fs-data|late-start|boot-complete}
#
# post-fs-data ：保证 /data 在挂载表中、自举 Magisk 运行环境、预开启 Zygisk，
#                 并在 /sbin/magisk --post-fs-data 之前安装镜像内置的 Magisk 模块。
#                 Magisk 会在同一轮启动中把 modules_update 合并进 modules，
#                 模块随后由 Zygisk 加载——不需要重启容器。
# late-start   ：安装 Xposed 应用并写入 LSPosed 默认启用/作用域，随后 lspd 启动。
# boot-complete ：安装各模块自带的管理器，补装 Magisk 管理器。
#
# 运行日志：/data/adb/.droid-kit/boot.log

MODULE_ZIPS="/system/etc/module-zips"
XPOSED="/system/etc/xposed-modules"
MAGISKBIN="/data/adb/magisk"
MARKERS="/data/adb/.droid-kit"
LOG="${MARKERS}/boot.log"
SQLRUN="/system/etc/droid-kit/sqlrun"
LSPD_CONFIG="/data/adb/lspd/config/modules_config.db"
LSPOSED_MODULES="com.android1500.gpssetter com.app.fakesensor com.waydroid.networkspoof"
XPOSED_CONF="/system/etc/droid-kit/xposed-modules.conf"
HMD_PKG="io.github.imkamaran.hidemydevice"
TSP_PKG="com.brianwalczak.telephonyspoofer"

mkdir -p "${MARKERS}" 2>/dev/null
log() { echo "$(date '+%m-%d %H:%M:%S') $*" >>"${LOG}" 2>/dev/null; }

install_xposed_prefs() {
    pkg="$1"
    prefs="$2"
    tmpl="$3"
    [ -f "$tmpl" ] || return
    dir="/data/user/0/$pkg"
    uid="$(pm list packages -U 2>/dev/null | sed -n "s/^package:$pkg uid:\([0-9]*\).*/\1/p" | head -n1)"
    [ -n "$uid" ] || uid="$(dumpsys package "$pkg" 2>/dev/null | sed -n 's/.*userId=\([0-9]*\).*/\1/p' | head -n1)"
    [ -n "$uid" ] || {
        log "prefs: uid not found: $pkg"
        return
    }
    for base in "/data/user/0/$pkg" "/data/data/$pkg"; do
        mkdir -p "$base/shared_prefs"
        cp "$tmpl" "$base/shared_prefs/$prefs.xml"
        chown -R "$uid:$uid" "$base"
        chmod 0771 "$base" "$base/shared_prefs" 2>/dev/null
        chmod 0666 "$base/shared_prefs/$prefs.xml" 2>/dev/null
    done
    # LSPosed 新版 XSharedPreferences 路径：/data/misc/<uuid>/prefs/<pkg>/<name>.xml
    for base in $(find /data/misc -mindepth 1 -maxdepth 1 -type d -name '*-*-*-*-*' 2>/dev/null); do
        mkdir -p "$base/prefs/$pkg"
        cp "$tmpl" "$base/prefs/$pkg/$prefs.xml"
        chmod 0771 "$base" "$base/prefs" "$base/prefs/$pkg" 2>/dev/null
        chmod 0666 "$base/prefs/$pkg/$prefs.xml" 2>/dev/null
    done
    log "prefs installed: $pkg/$prefs"
}

set_battery() {
    dumpsys battery set level 87 >/dev/null 2>&1
    dumpsys battery set temp 305 >/dev/null 2>&1
    dumpsys battery set status 2 >/dev/null 2>&1
    dumpsys battery set ac 1 >/dev/null 2>&1
    dumpsys battery set present 1 >/dev/null 2>&1
    log "battery spoof applied"
}

lsposed_configure() {
    [ -x "${SQLRUN}" ] || {
        log "lsposed config skipped: sqlrun missing"
        return
    }
    mkdir -p /data/adb/lspd/config
    chmod 0777 /data/adb/lspd /data/adb/lspd/config 2>/dev/null

    module_in=""
    module_values=""
    for p in ${LSPOSED_MODULES}; do
        apk_path="$(pm path "$p" 2>/dev/null | head -n1 | sed 's/^package://')"
        [ -n "$apk_path" ] || {
            log "lsposed: $p not installed, skipped"
            continue
        }
        module_in="${module_in},'$p'"
        module_values="${module_values},('$p','$apk_path',1)"
    done
    module_in="${module_in#,}"
    [ -n "$module_values" ] || {
        log "lsposed config skipped: no modules installed"
        return
    }

    pkg_values=""
    for p in $(pm list packages 2>/dev/null | sed 's/^package://'); do
        case " ${LSPOSED_MODULES} " in
        *" $p "*) continue ;;
        esac
        case "$p" in
        org.lsposed.manager | com.topjohnwu.magisk | org.frknkrc44.hma_oss | \
            android | system | com.android.systemui | com.android.providers.settings | \
            com.google.android.gms | com.google.android.gsf | com.android.vending)
            continue
            ;;
        esac
        pkg_values="${pkg_values},('$p')"
    done

    sql="
CREATE TABLE IF NOT EXISTS modules (
  mid integer PRIMARY KEY AUTOINCREMENT,
  module_pkg_name text NOT NULL UNIQUE,
  apk_path text NOT NULL,
  enabled BOOLEAN DEFAULT 0 CHECK (enabled IN (0, 1))
);
CREATE TABLE IF NOT EXISTS scope (
  mid integer,
  app_pkg_name text NOT NULL,
  user_id integer NOT NULL,
  PRIMARY KEY (mid, app_pkg_name, user_id),
  CONSTRAINT scope_module_constraint FOREIGN KEY (mid) REFERENCES modules (mid) ON DELETE CASCADE
);
CREATE TABLE IF NOT EXISTS configs (
  module_pkg_name text NOT NULL,
  user_id integer NOT NULL,
  [group] text NOT NULL,
  [key] text NOT NULL,
  data blob NOT NULL,
  PRIMARY KEY (module_pkg_name, user_id, [group], [key]),
  CONSTRAINT config_module_constraint FOREIGN KEY (module_pkg_name) REFERENCES modules (module_pkg_name) ON DELETE CASCADE
);
CREATE TABLE IF NOT EXISTS android_metadata (locale TEXT);
DELETE FROM android_metadata;
INSERT INTO android_metadata(locale) VALUES('en_US');
INSERT OR IGNORE INTO modules(module_pkg_name,apk_path,enabled) VALUES ${module_values#,};
UPDATE modules SET enabled=1 WHERE module_pkg_name IN (${module_in});
DELETE FROM scope WHERE app_pkg_name IN ('system','android')
  AND mid IN (SELECT mid FROM modules WHERE module_pkg_name IN (${module_in}));
"
    if [ -n "$pkg_values" ]; then
        sql="${sql}
CREATE TEMP TABLE pkg(pkg TEXT);
INSERT INTO pkg(pkg) VALUES ${pkg_values#,};
INSERT OR IGNORE INTO scope(mid,app_pkg_name,user_id)
  SELECT m.mid,p.pkg,0 FROM modules m CROSS JOIN pkg p WHERE m.module_pkg_name IN (${module_in});
"
    fi

    if "${SQLRUN}" "${LSPD_CONFIG}" "$sql" >>"$LOG" 2>&1; then
        chmod 0666 "${LSPD_CONFIG}" 2>/dev/null
        log "lsposed configured: $(echo "$module_values" | grep -o "('" | wc -l) module(s)"
    else
        log "lsposed config FAILED"
    fi
}

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

    # magiskd 由 --setup-sbin 启动；sqlite 与模块安装都依赖它
    /sbin/magisk --daemon >/dev/null 2>&1

    # 测试容器默认关闭 adb 认证，便于宿主机/开发容器直接 adb/scrcpy
    /sbin/resetprop ro.adb.secure 0 >/dev/null 2>&1
    setprop ctl.restart adbd >/dev/null 2>&1
    log "adb auth disabled"

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

    # LSPosed 的 post-fs-data.sh 会提前启动 lspd，导致 late-start 写入的配置
    # 被启动时的缓存忽略。移除该启动行，让 lspd 只由 service.sh 在 late-start 后启动。
    for pfd in /data/adb/modules_update/zygisk_lsposed/post-fs-data.sh \
               /data/adb/modules/zygisk_lsposed/post-fs-data.sh; do
        [ -f "$pfd" ] || continue
        sed -i '/unshare -m sh -c/d' "$pfd"
        log "lsposed post-fs-data daemon start disabled"
    done

    # LSPosed 启动后 system_server 可能软重启一次，会再次触发 boot-complete；
    # 每轮启动只执行一次，避免重复安装管理器。
    rm -f "${MARKERS}/boot-complete-done" 2>/dev/null
    ;;

late-start)
    # 系统启动完成后安装 Xposed 应用，并补齐 LSPosed 的默认作用域。
    mkdir -p "${MARKERS}/xposed"

    # package 服务在 boot_completed 之前可能还不接受 install；先等系统完成启动
    i=0
    while [ "$(getprop sys.boot_completed)" != "1" ]; do
        i=$((i + 1))
        [ $i -ge 150 ] && break
        sleep 2
    done

    for f in "${XPOSED}"/*; do
        [ -f "$f" ] || continue
        b="$(basename "$f")"
        [ -e "${MARKERS}/xposed/$b" ] && continue
        log "xposed install: $b"
        out="$(pm install -r "$f" 2>&1)"
        case "$out" in
        *Success*)
            touch "${MARKERS}/xposed/$b"
            log "xposed installed: $b"
            ;;
        *)
            log "xposed install FAILED: $b: $out"
            ;;
        esac
    done
    sleep 1

    install_xposed_prefs "$HMD_PKG" ids /system/etc/droid-kit/hidemydevice-ids.xml
    install_xposed_prefs "$TSP_PKG" config /system/etc/droid-kit/telephonyspoofer-config.xml

    # 从映射文件读取 Xposed 模块包名；新增 APK 只需修改 xposed-modules.conf
    if [ -f "${XPOSED_CONF}" ]; then
        LSPOSED_MODULES=""
        while read -r apk pkg; do
            case "$apk" in
            '' | '#'*) continue ;;
            esac
            [ -n "$pkg" ] && LSPOSED_MODULES="${LSPOSED_MODULES} $pkg"
        done <"${XPOSED_CONF}"
        LSPOSED_MODULES="${LSPOSED_MODULES# }"
    fi

    lsposed_configure
    ;;

boot-complete)
    if [ -e "${MARKERS}/boot-complete-done" ]; then
        # system_server 软重启后会再次触发；此时 Magisk 管理器可能已被 fork 卸载
        sleep 30
        install_xposed_prefs "$HMD_PKG" ids /system/etc/droid-kit/hidemydevice-ids.xml
        install_xposed_prefs "$TSP_PKG" config /system/etc/droid-kit/telephonyspoofer-config.xml
        if ! pm path com.topjohnwu.magisk >/dev/null 2>&1; then
            pm install /system/etc/init/magisk/magisk.apk >/dev/null 2>&1 \
                && log "manager reinstalled (post-restart)"
        fi
        set_battery
        log "=== boot-complete already done (system_server restart) ==="
        exit 0
    fi
    sleep 20
    install_xposed_prefs "$HMD_PKG" ids /system/etc/droid-kit/hidemydevice-ids.xml
    install_xposed_prefs "$TSP_PKG" config /system/etc/droid-kit/telephonyspoofer-config.xml
    mkdir -p "${MARKERS}/managers"

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
    set_battery
    log "=== boot-complete done ==="
    touch "${MARKERS}/boot-complete-done" 2>/dev/null
    ;;
esac

exit 0