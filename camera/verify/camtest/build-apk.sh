#!/usr/bin/env bash
# Build the banchmark/verification APK without Gradle.
#
# Requirements (Android SDK):
#   * build-tools with aapt2, d8, zipalign, apksigner
#   * platforms/android-31/android.jar
# Override paths with BUILD_TOOLS=... and ANDROID_JAR=...
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
BUILD_TOOLS=${BUILD_TOOLS:-${ANDROID_HOME:-$HOME/Android/Sdk}/build-tools/33.0.2}
ANDROID_JAR=${ANDROID_JAR:-${ANDROID_HOME:-$HOME/Android/Sdk}/platforms/android-31/android.jar}
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
    -d "$OUT/classes" "$here"/src/org/droidkit/camtest/*.java

"$BUILD_TOOLS/d8" --lib "$ANDROID_JAR" --min-api 30 \
    --output "$OUT/dex" $(find "$OUT/classes" -name '*.class')

(cd "$OUT" && zip -j base.apk dex/classes.dex >/dev/null)
"$BUILD_TOOLS/zipalign" -f 4 "$OUT/base.apk" "$OUT/aligned.apk"

if [[ ! -f "$OUT/debug.keystore" ]]; then
    keytool -genkeypair -keystore "$OUT/debug.keystore" \
        -storepass android -keypass android -alias debug \
        -keyalg RSA -keysize 2048 -validity 10000 -dname "CN=camtest" >/dev/null 2>&1
fi

"$BUILD_TOOLS/apksigner" sign \
    --ks "$OUT/debug.keystore" --ks-pass pass:android --key-pass pass:android \
    --out "$OUT/camtest.apk" "$OUT/aligned.apk"

echo "built: $OUT/camtest.apk"
