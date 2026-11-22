#!/bin/sh
# 整理 modules/ 下的模块，分类打包进镜像：
#   - 含 module.prop 的 zip -> Magisk 模块，原样放到 system/etc/module-zips/
#     （首次启动由 magisk --install-module 走完整安装流水线，含 customize.sh）
#   - APK -> Xposed 模块，原样放到 system/etc/xposed-modules/
# 用法：prepare-modules.sh <modules 源目录> <staged 根目录>

set -eu

SRC="${1:?usage: prepare-modules.sh <modules-src> <staged-root>}"
STAGED="${2:?usage: prepare-modules.sh <modules-src> <staged-root>}"

MODULE_ZIPS="$STAGED/system/etc/module-zips"
XPOSED_DIR="$STAGED/system/etc/xposed-modules"
mkdir -p "$MODULE_ZIPS" "$XPOSED_DIR" /tmp/module-work

count_magisk=0
count_xposed=0
count_failed=0

for f in "$SRC"/*; do
    [ -f "$f" ] || continue
    name="$(basename "$f")"
    case "$name" in
    *.apk)
        # APK 直接视为 Xposed 模块（Magisk 模块不会以 .apk 形式分发）
        cp "$f" "$XPOSED_DIR/$name"
        echo "xposed module : $name -> xposed-modules/"
        count_xposed=$((count_xposed + 1))
        continue
        ;;
    *.zip) ;;
        *)
        echo "WARNING: $name is not a zip/apk, skipped" >&2
        continue
        ;;
    esac

    work="/tmp/module-work/$name"
    rm -rf "$work"
    mkdir -p "$work"
    if ! bsdtar -xf "$f" -C "$work"; then
        echo "WARNING: cannot unpack $name, skipped" >&2
        count_failed=$((count_failed + 1))
        continue
    fi

    if [ -f "$work/module.prop" ]; then
        cp "$f" "$MODULE_ZIPS/$name"
        echo "magisk module : $name -> module-zips/"
        count_magisk=$((count_magisk + 1))
    else
        echo "WARNING: $name has no module.prop, skipped" >&2
    fi
done

echo "staged: $count_magisk magisk module(s), $count_xposed xposed module(s)"
if [ "$count_magisk" -eq 0 ]; then
    echo "ERROR: no Magisk module found in modules/ (Shamiko / PlayIntegrityFork / LSPosed should be placed there)" >&2
    exit 1
fi
if [ "$count_failed" -gt 0 ]; then
    echo "ERROR: $count_failed file(s) in modules/ failed to unpack — fix or remove them and rebuild" >&2
    exit 1
fi
exit 0
