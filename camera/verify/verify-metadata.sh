#!/usr/bin/env bash
# Verify the static camera metadata of the upgraded Android 12 legacy V4L2 HAL.
#
# The HAL is expected to expose two cameras (0 = back, 1 = front) with a fixed
# metadata profile: distortion correction OFF, no flash/LED, 1920x1080 sensor
# arrays, four JPEG thumbnail sizes and 640x480 / 1280x720 / 1920x1080 stream
# configurations.
#
# Reads `dumpsys media.camera` from a running reDroid container, prints PASS or
# FAIL for every check and exits non-zero if anything is missing.
#
# Env:
#   PORT       adb TCP port of the container      (default 5557)
#   HOST_IP    adb host                           (default 127.0.0.1)
#   ADB        adb binary                         (default adb)
#   TARGET     override HOST_IP:PORT
#   SERIAL     override adb serial
#   DUMP       write dumpsys output to this path  (default: mktemp)
#   KEEP_DUMP  set to 1 to keep the raw dump after a successful run
set -euo pipefail

ADB=${ADB:-adb}
HOST_IP=${HOST_IP:-127.0.0.1}
PORT=${PORT:-5557}
TARGET=${TARGET:-$HOST_IP:$PORT}
SERIAL=${SERIAL:-$TARGET}
KEEP_DUMP=${KEEP_DUMP:-0}

passed=0
failed=0
status=0
pass() { printf 'PASS  %s\n' "$1"; passed=$((passed + 1)); }
fail() { printf 'FAIL  %s\n' "$1"; failed=$((failed + 1)); status=1; }
note() { printf '      %s\n' "$1"; }

# ---------------------------------------------------------------- connect ---

"$ADB" connect "$TARGET" >/dev/null 2>&1 || true
if ! timeout 60 "$ADB" -s "$SERIAL" wait-for-device >/dev/null 2>&1; then
  echo "error: $SERIAL not ready (adb connect failed)" >&2
  exit 1
fi

# adbd comes up before the provider is restarted at boot_completed.
boot=
for _ in $(seq 1 60); do
  boot=$("$ADB" -s "$SERIAL" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')
  [[ "$boot" == "1" ]] && break
  sleep 2
done
if [[ "$boot" != "1" ]]; then
  echo "error: sys.boot_completed never became 1" >&2
  exit 1
fi

# ------------------------------------------------------------------ dump ---

DUMP=${DUMP:-$(mktemp "${TMPDIR:-/tmp}/droid-kit-camera-dump.XXXXXX")}
cleanup() {
  if [[ "$status" -eq 0 && "$KEEP_DUMP" != "1" ]]; then
    rm -f "$DUMP"
  fi
}
trap cleanup EXIT

echo "=== dumpsys media.camera ($SERIAL) ==="
for _ in $(seq 1 15); do
  "$ADB" -s "$SERIAL" shell dumpsys media.camera >"$DUMP" 2>/dev/null || true
  grep -qE '^Number of camera devices: 2[[:space:]]*$' "$DUMP" && break
  sleep 2
done
echo "raw dump: $DUMP"

# ------------------------------------------------------- metadata parsing ---
#
# `dumpsys media.camera` prints each static metadata entry as:
#
#     android.sensor.info.pixelArraySize (0001): int32[2]
#         [1920 1080 ]
#
# tag_meta() prints "<count> <values...>" for the first occurrence of a tag
# (one occurrence per camera; both cameras are expected to agree) and exits 3
# when the tag is absent. Values are flattened to a single space-separated line
# so they can be matched without depending on the 4/8/16-values-per-line
# wrapping of CameraMetadata::dump().
tag_meta() {
  awk -v want="android.$1" '
    $1 == want && $2 ~ /^\([0-9a-fA-F]+\):$/ {
      if (found) exit
      found = 1
      count = $3
      sub(/^[^[]*\[/, "", count)
      sub(/\].*/, "", count)
      next
    }
    found {
      if ($1 ~ /^android\./ || $0 ~ /^[[:space:]]*==/) exit
      if ($0 ~ /^[[:space:]]*\[/) {
        line = $0
        gsub(/^[[:space:]]*\[/, "", line)
        gsub(/\][[:space:]]*$/, "", line)
        vals = vals " " line
      }
    }
    END {
      if (!found) exit 3
      gsub(/[[:space:]]+/, " ", vals)
      sub(/^ /, "", vals)
      sub(/ $/, "", vals)
      printf "%s %s\n", count, vals
    }
  ' "$DUMP"
}

# read_meta TAG -> sets META_COUNT / META_VALUES, returns 1 when the tag is
# missing from the dump.
read_meta() {
  local out
  if ! out=$(tag_meta "$1"); then
    META_COUNT=
    META_VALUES=
    return 1
  fi
  META_COUNT=${out%% *}
  case "$out" in
    *" "*) META_VALUES=${out#* } ;;
    *)     META_VALUES= ;;
  esac
  return 0
}

# Enum values are printed symbolically by CameraMetadata::dump(), but accept
# the numeric value too so the checks also work on builds without enum names.
uppercase() { printf '%s' "$1" | tr '[:lower:]' '[:upper:]'; }

# ---------------------------------------------------------------- checks ---

echo
echo "=== checks ==="

# 1. Two cameras are visible to the camera service.
if grep -qE '^Number of camera devices: 2[[:space:]]*$' "$DUMP"; then
  pass "camera count is 2"
else
  actual=$(grep -m1 '^Number of camera devices:' "$DUMP" | tr -d '\r' || true)
  fail "camera count is 2"
  note "got: ${actual:-<missing>}"
fi

# 2. API1 facing: one back camera and one front camera.
if grep -qE '^[[:space:]]*Facing: Back[[:space:]]*$' "$DUMP"; then
  pass "API1 facing Back present"
else
  fail "API1 facing Back present"
fi
if grep -qE '^[[:space:]]*Facing: Front[[:space:]]*$' "$DUMP"; then
  pass "API1 facing Front present"
else
  fail "API1 facing Front present"
fi
api1_sections=$(grep -cE '^[[:space:]]*API1 info:' "$DUMP" || true)
if [[ "$api1_sections" == "2" ]]; then
  pass "two API1 info sections"
else
  fail "two API1 info sections"
  note "got: $api1_sections"
fi

# 3. Distortion correction advertises the OFF mode.
if read_meta distortionCorrection.availableModes; then
  modes_up=$(uppercase "$META_VALUES")
  if [[ " $modes_up " == *" OFF "* || " $modes_up " == *" 0 "* ]]; then
    pass "distortionCorrection.availableModes contains OFF"
  else
    fail "distortionCorrection.availableModes contains OFF"
    note "got: [$META_VALUES]"
  fi
else
  fail "distortionCorrection.availableModes is present"
fi

# 4. Flash is unavailable and there is no TRANSMIT LED.
if read_meta flash.info.available; then
  flash_up=$(uppercase "$META_VALUES")
  if [[ " $flash_up " == *" FALSE "* || " $flash_up " == *" 0 "* ]]; then
    pass "flash.info.available is FALSE"
  else
    fail "flash.info.available is FALSE"
    note "got: [$META_VALUES]"
  fi
else
  fail "flash.info.available is present"
fi

if read_meta led.availableLeds; then
  leds_up=$(uppercase "$META_VALUES")
  if [[ " $leds_up " == *" TRANSMIT "* ]]; then
    fail "led.availableLeds has no TRANSMIT"
    note "got: [$META_VALUES]"
  else
    pass "led.availableLeds has no TRANSMIT (empty list)"
  fi
else
  fail "led.availableLeds is present"
fi

# 5. Sensor arrays are 1920x1080.
if read_meta sensor.info.pixelArraySize; then
  if [[ "$META_VALUES" == "1920 1080" ]]; then
    pass "sensor.info.pixelArraySize is 1920 1080"
  else
    fail "sensor.info.pixelArraySize is 1920 1080"
    note "got: [$META_VALUES]"
  fi
else
  fail "sensor.info.pixelArraySize is present"
fi

if read_meta sensor.info.activeArraySize; then
  last_two=$(awk '{ if (NF >= 2) print $(NF-1), $NF }' <<<"$META_VALUES")
  if [[ "$META_COUNT" == "4" && "$last_two" == "1920 1080" ]]; then
    pass "sensor.info.activeArraySize ends with 1920 1080"
  else
    fail "sensor.info.activeArraySize ends with 1920 1080"
    note "count=$META_COUNT values=[$META_VALUES]"
  fi
else
  fail "sensor.info.activeArraySize is present"
fi

# 6. JPEG thumbnail sizes: exactly four ints.
if read_meta jpeg.availableThumbnailSizes; then
  thumb_n=0
  for _ in $META_VALUES; do thumb_n=$((thumb_n + 1)); done
  if [[ "$META_COUNT" == "4" && "$thumb_n" -eq 4 ]]; then
    pass "jpeg.availableThumbnailSizes has 4 values"
  else
    fail "jpeg.availableThumbnailSizes has 4 values"
    note "count=$META_COUNT values=[$META_VALUES]"
  fi
else
  fail "jpeg.availableThumbnailSizes is present"
fi

# 7. Scaler stream configurations include all three tested resolutions.
# Each entry is a 4-tuple (format, width, height, input); values are flattened,
# so group them by four and collect WxH pairs.
if read_meta scaler.availableStreamConfigurations; then
  resolutions=$(awk '{ for (i = 1; i + 2 <= NF; i += 4) print $(i+1) "x" $(i+2) }' \
    <<<"$META_VALUES")
  for want in 640x480 1280x720 1920x1080; do
    if grep -qx "$want" <<<"$resolutions"; then
      pass "stream config $want present"
    else
      fail "stream config $want present"
    fi
  done
else
  fail "scaler.availableStreamConfigurations is present"
  for want in 640x480 1280x720 1920x1080; do
    fail "stream config $want present"
  done
fi

echo
printf '=== %d passed, %d failed ===\n' "$passed" "$failed"
exit "$status"
