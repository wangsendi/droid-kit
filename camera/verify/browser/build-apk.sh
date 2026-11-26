#!/usr/bin/env bash
# Build the minimal WebView browser APK (no Gradle).
set -euo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
BUILD_TOOLS=${BUILD_TOOLS:-/tmp/opencode/bt33/android-13}
ANDROID_JAR=${ANDROID_JAR:-/app/data/aosp12/prebuilts/sdk/25/public/android.jar}
OUT=${OUT:-$here/build}

[[ -x "$BUILD_TOOLS/aapt2" ]] || { echo "error: aapt2 not found in $BUILD_TOOLS" >&2; exit 1; }
[[ -f "$ANDROID_JAR" ]] || { echo "error: android.jar not found: $ANDROID_JAR" >&2; exit 1; }

rm -rf "$OUT"
mkdir -p "$OUT/classes" "$OUT/dex"

"$BUILD_TOOLS/aapt2" link \
    -o "$OUT/base.apk" -I "$ANDROID_JAR" \
    --manifest "$here/AndroidManifest.xml" -A "$here/assets" \
    --min-sdk-version 30 --target-sdk-version 31 \
    --version-code 1 --version-name 1.0

javac -source 8 -target 8 -bootclasspath "$ANDROID_JAR" -classpath "$ANDROID_JAR" \
    -d "$OUT/classes" "$here"/src/org/droidkit/browser/*.java

"$BUILD_TOOLS/d8" --lib "$ANDROID_JAR" --min-api 30 \
    --output "$OUT/dex" $(find "$OUT/classes" -name '*.class')

(cd "$OUT" && zip -j base.apk dex/classes.dex >/dev/null)
"$BUILD_TOOLS/zipalign" -f 4 "$OUT/base.apk" "$OUT/aligned.apk"

KEYSTORE=${KEYSTORE:-$here/debug.keystore}
if [[ ! -f "$KEYSTORE" ]]; then
    keytool -genkeypair -keystore "$KEYSTORE" \
        -storepass android -keypass android -alias debug \
        -keyalg RSA -keysize 2048 -validity 10000 -dname "CN=browser" >/dev/null 2>&1
fi

"$BUILD_TOOLS/apksigner" sign \
    --ks "$KEYSTORE" --ks-pass pass:android --key-pass pass:android \
    --out "$OUT/browser.apk" "$OUT/aligned.apk"

echo "built: $OUT/browser.apk"
