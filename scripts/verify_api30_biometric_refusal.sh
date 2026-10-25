#!/usr/bin/env bash
#
# Executes the instrumented test that pins Vaulta's API < 30 biometric refusal.
#
# It boots the `vaulta-a10` AVD (API 29, system-images;android-29;google_apis;x86_64)
# headless, installs the debug APK plus the androidTest APK and runs
# com.insyd.gestor_contrasenas.KeystoreChannelApiRefusalTest through
# androidx.test.runner.AndroidJUnitRunner on that device, then prints which
# test passed, failed or was skipped by assumption.
#
# The recording of the run this produced is docs/reference/api30-biometric-refusal-verification.md.
#
# Usage:
#   bash scripts/verify_api30_biometric_refusal.sh [avd_name]
#
# Environment:
#   ANDROID_HOME / ANDROID_SDK_ROOT  Android SDK root (default: ~/Android/Sdk)
#   ANDROID_AVD_HOME                 AVD directory when it is not the default
#   FLUTTER_BIN                      flutter executable (default: from PATH)
#   KEEP_EMULATOR=1                  leave the emulator running after the run
#
# Exit codes:
#   0  every test applicable to this device passed
#   1  a test failed
#   2  the environment cannot run the suite (SDK, emulator, KVM, AVD, flutter)

set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ANDROID_DIR="$REPO_ROOT/android"

AVD_NAME="${1:-vaulta-a10}"
API_LEVEL_UNDER_TEST=29
IMAGE_PACKAGE="system-images;android-29;google_apis;x86_64"
IMAGE_DIR="android-29/google_apis/x86_64"
DEVICE_CLASS="pixel_5"

APP_ID="com.insyd.gestor_contrasenas"
TEST_PACKAGE="${APP_ID}.test"
TEST_RUNNER="androidx.test.runner.AndroidJUnitRunner"
TEST_CLASS="${APP_ID}.KeystoreChannelApiRefusalTest"

EMULATOR_CORES=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)
if [ "$EMULATOR_CORES" -gt 4 ]; then EMULATOR_CORES=4; fi

log() { printf '%s %s\n' '[verify-api30]' "$*"; }
fail() {
  printf '%s %s\n' '[verify-api30] ERROR:' "$*" >&2
  exit 2
}

cleanup() {
  local status=$?
  [ -n "${RAW_REPORT:-}" ] && rm -f "$RAW_REPORT"
  if [ -n "${EMULATOR_PID:-}" ] && [ -z "${KEEP_EMULATOR:-}" ]; then
    log "stopping the emulator"
    "$ADB" -s "${DEVICE:-emulator-5554}" emu kill >/dev/null 2>&1 ||
      kill "$EMULATOR_PID" 2>/dev/null || true
  fi
  exit "$status"
}
trap cleanup EXIT

SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Android/Sdk}}"
ADB="$SDK/platform-tools/adb"
EMULATOR="$SDK/emulator/emulator"
AVDMANAGER="$SDK/cmdline-tools/latest/bin/avdmanager"

[ -d "$SDK" ] || fail "no Android SDK at $SDK (set ANDROID_HOME)"
[ -x "$ADB" ] || fail "no adb at $ADB"
[ -x "$EMULATOR" ] || fail "no emulator at $EMULATOR"
[ -d "$SDK/system-images/$IMAGE_DIR" ] || fail \
  "the API 29 image is not installed: $SDK/system-images/$IMAGE_DIR (sdkmanager \"$IMAGE_PACKAGE\")"
[ -r /dev/kvm ] || fail "no /dev/kvm: the API $API_LEVEL_UNDER_TEST emulator needs KVM acceleration"

FLUTTER_BIN="${FLUTTER_BIN:-$(command -v flutter || true)}"
[ -n "$FLUTTER_BIN" ] || fail "flutter is not on PATH (set FLUTTER_BIN)"
FLUTTER_SDK=$(cd "$(dirname "$(readlink -f "$FLUTTER_BIN")")/.." && pwd)

# --- AVD home ------------------------------------------------------------
#
# avdmanager writes to $ANDROID_USER_HOME (XDG: ~/.config/.android) while the
# emulator reads $ANDROID_AVD_HOME or ~/.android/avd. Pick whichever directory
# already holds the AVD and export it so both tools agree.
avd_home_with_avd() {
  local dir
  for dir in "${ANDROID_AVD_HOME:-}" "$HOME/.android/avd" \
    "${XDG_CONFIG_HOME:-$HOME/.config}/.android/avd"; do
    if [ -n "$dir" ] && [ -f "$dir/$AVD_NAME.ini" ]; then
      printf '%s\n' "$dir"
      return 0
    fi
  done
  return 1
}

if ANDROID_AVD_HOME=$(avd_home_with_avd); then
  export ANDROID_AVD_HOME
else
  if [ -z "${ANDROID_AVD_HOME:-}" ]; then
    ANDROID_AVD_HOME="${XDG_CONFIG_HOME:-$HOME/.config}/.android/avd"
    export ANDROID_AVD_HOME
  fi
  [ -x "$AVDMANAGER" ] || fail "AVD $AVD_NAME is missing and there is no avdmanager at $AVDMANAGER"
  log "creating AVD $AVD_NAME ($IMAGE_PACKAGE)"
  echo no | "$AVDMANAGER" create avd -n "$AVD_NAME" -k "$IMAGE_PACKAGE" \
    -d "$DEVICE_CLASS" --force >/dev/null 2>&1 || fail "could not create AVD $AVD_NAME"
fi

"$EMULATOR" -list-avds | grep -qx "$AVD_NAME" || fail \
  "the emulator does not list AVD $AVD_NAME (ANDROID_AVD_HOME=$ANDROID_AVD_HOME)"

# --- device --------------------------------------------------------------
#
# Reuse an already running device only when it really is an API 29 one,
# otherwise boot the AVD and identify it as the serial that was not there
# before.
serial_sdk() {
  "$ADB" -s "$1" shell getprop ro.build.version.sdk 2>/dev/null | tr -d '\r'
}

attached_devices() {
  "$ADB" devices | awk 'NR > 1 && $2 == "device" { print $1 }'
}

DEVICE=""
for serial in $(attached_devices); do
  if [ "$(serial_sdk "$serial")" = "$API_LEVEL_UNDER_TEST" ]; then
    DEVICE="$serial"
    log "reusing the API $API_LEVEL_UNDER_TEST device already attached: $DEVICE"
    break
  fi
done

EMULATOR_PID=""
if [ -z "$DEVICE" ]; then
  BEFORE=$(attached_devices | sort)
  log "booting AVD $AVD_NAME (headless)"
  "$EMULATOR" -avd "$AVD_NAME" \
    -no-window -no-audio -no-boot-anim -no-snapshot \
    -gpu swiftshader_indirect -cores "$EMULATOR_CORES" \
    -netdelay none -netspeed full >"/tmp/vaulta-a10-emulator.log" 2>&1 &
  EMULATOR_PID=$!

  log "waiting for the device to attach (log: /tmp/vaulta-a10-emulator.log)"
  for _ in $(seq 1 120); do
    DEVICE=$(attached_devices | sort | comm -13 <(printf '%s\n' "$BEFORE") - | head -1)
    if [ -n "$DEVICE" ]; then break; fi
    sleep 2
  done
  [ -n "$DEVICE" ] || fail "the emulator never attached to adb"

  log "waiting for $DEVICE to finish booting"
  for _ in $(seq 1 180); do
    if [ "$("$ADB" -s "$DEVICE" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ]; then
      break
    fi
    sleep 2
  done
fi

"$ADB" -s "$DEVICE" wait-for-device
DEVICE_SDK=$(serial_sdk "$DEVICE")
DEVICE_RELEASE=$("$ADB" -s "$DEVICE" shell getprop ro.build.version.release | tr -d '\r')
log "device $DEVICE is Android $DEVICE_RELEASE (API $DEVICE_SDK)"

# --- build ---------------------------------------------------------------
#
# Gradle needs android/local.properties for the Flutter SDK path; it is
# gitignored, so write it when the checkout does not have one.
LOCAL_PROPERTIES="$ANDROID_DIR/local.properties"
touch "$LOCAL_PROPERTIES"
grep -q '^flutter\.sdk=' "$LOCAL_PROPERTIES" ||
  printf 'flutter.sdk=%s\n' "$FLUTTER_SDK" >>"$LOCAL_PROPERTIES"
grep -q '^sdk\.dir=' "$LOCAL_PROPERTIES" ||
  printf 'sdk.dir=%s\n' "$SDK" >>"$LOCAL_PROPERTIES"

if [ -x "$ANDROID_DIR/gradlew" ]; then
  GRADLE=(env ANDROID_HOME="$SDK" ANDROID_SDK_ROOT="$SDK" "$ANDROID_DIR/gradlew")
else
  GRADLE_BIN=$(command -v gradle || true)
  [ -n "$GRADLE_BIN" ] || fail "no android/gradlew and no gradle on PATH"
  GRADLE=(env ANDROID_HOME="$SDK" ANDROID_SDK_ROOT="$SDK" "$GRADLE_BIN")
fi

log "building the debug APK and the androidTest APK"
(cd "$ANDROID_DIR" && "${GRADLE[@]}" --console=plain \
  :app:assembleDebug :app:assembleDebugAndroidTest)

APK_DIR="$REPO_ROOT/build/app/outputs/apk"
APP_APK="$APK_DIR/debug/app-debug.apk"
TEST_APK="$APK_DIR/androidTest/debug/app-debug-androidTest.apk"
[ -f "$APP_APK" ] || fail "the debug APK was not produced at $APP_APK"
[ -f "$TEST_APK" ] || fail "the androidTest APK was not produced at $TEST_APK"

log "installing $APP_ID and its instrumentation APK"
"$ADB" -s "$DEVICE" install -r -t "$APP_APK" >/dev/null
"$ADB" -s "$DEVICE" install -r -t "$TEST_APK" >/dev/null

# --- run -----------------------------------------------------------------
#
# `-r` prints the raw status stream so the per-test outcome can be printed
# from it instead of only the final count, and so an assumption failure
# (the API 30+ branch on this API 29 device) shows up as "skipped", not as
# a pass.
RAW_REPORT=$(mktemp)

log "running $TEST_CLASS on API $DEVICE_SDK"
set +e
timeout 900 "$ADB" -s "$DEVICE" shell am instrument -w -r \
  -e class "$TEST_CLASS" \
  "$TEST_PACKAGE/$TEST_RUNNER" >"$RAW_REPORT" 2>&1
INSTRUMENT_EXIT=$?
set -e
if [ "$INSTRUMENT_EXIT" -eq 124 ]; then
  fail "the instrumentation did not finish within 15 minutes on $DEVICE"
fi

# The status stream is unescaped multi-line output, so fold each
# INSTRUMENTATION_STATUS block into a single record before printing it.
awk '
  /^INSTRUMENTATION_STATUS: / {
    line = substr($0, length("INSTRUMENTATION_STATUS: ") + 1)
    if (line ~ /^(class|test|stack)=/) {
      key = line; sub(/=.*/, "", key)
      value = line; sub(/^[^=]*=/, "", value)
      if (key == "class") currentClass = value
      if (key == "test") currentTest = value
      if (key == "stack") currentStack = value
      next
    }
  }
  /^INSTRUMENTATION_STATUS_CODE: / {
    code = substr($0, length("INSTRUMENTATION_STATUS_CODE: ") + 1)
    if (code == "0") printf "  PASS     %s\n", currentTest
    else if (code == "-2") printf "  FAIL     %s\n%s\n", currentTest, currentStack
    else if (code == "-3" || code == "-4") printf "  SKIPPED  %s\n", currentTest
    next
  }
  /^(INSTRUMENTATION_RESULT: |INSTRUMENTATION_CODE: )/ { print }
' "$RAW_REPORT"

if grep -q '^INSTRUMENTATION_STATUS_CODE: -2' "$RAW_REPORT"; then
  log "RESULT: FAILED on API $DEVICE_SDK (see the FAIL lines above)"
  exit 1
fi
if ! grep -q '^OK (' "$RAW_REPORT"; then
  log "RESULT: FAILED - the runner did not report a clean run on API $DEVICE_SDK"
  exit 1
fi
log "RESULT: PASSED on API $DEVICE_SDK"
