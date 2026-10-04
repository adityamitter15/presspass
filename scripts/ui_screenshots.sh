#!/usr/bin/env bash
# Builds the Dev app for the iPhone 17 Pro simulator (iOS 26.5), runs it on
# the replayed demo session, and saves screenshots and a short video of the
# home, workout and summary screens. No camera or device needed.
#
# usage: scripts/ui_screenshots.sh [output-dir]     (default build/ui-shots)
set -euo pipefail

cd "$(dirname "$0")/.."
OUT="${1:-build/ui-shots}"
DEVICE_NAME="iPhone 17 Pro"
RUNTIME="com.apple.CoreSimulator.SimRuntime.iOS-26-5"
SCHEME="PushupTimeDev"
BUNDLE_ID="com.addymitter.pushuptime.dev"
DERIVED="build"
APP="$DERIVED/Build/Products/Debug-iphonesimulator/$SCHEME.app"
BUILD_LOG="$DERIVED/ui-screenshots-build.log"

mkdir -p "$OUT" "$DERIVED"

# The simulator's UDID, since more than one runtime has an "iPhone 17 Pro".
UDID="$(xcrun simctl list devices available -j | python3 -c '
import json, sys
name, runtime = sys.argv[1], sys.argv[2]
devices = json.load(sys.stdin)["devices"].get(runtime, [])
match = [d["udid"] for d in devices if d["name"] == name]
print(match[0] if match else "")
' "$DEVICE_NAME" "$RUNTIME")"
if [[ -z "$UDID" ]]; then
    echo "error: no '$DEVICE_NAME' simulator on $RUNTIME" >&2
    exit 1
fi

RECORDER_PID=""
cleanup() {
    if [[ -n "$RECORDER_PID" ]]; then
        kill -INT "$RECORDER_PID" 2>/dev/null || true
    fi
    xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
    xcrun simctl status_bar "$UDID" clear >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "building $SCHEME for $DEVICE_NAME ($UDID)"
if ! xcodebuild -workspace PushupTime.xcworkspace -scheme "$SCHEME" \
    -destination "platform=iOS Simulator,id=$UDID" \
    -derivedDataPath "$DERIVED" build >"$BUILD_LOG" 2>&1; then
    tail -40 "$BUILD_LOG" >&2
    echo "error: build failed, full log in $BUILD_LOG" >&2
    exit 1
fi

xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b >/dev/null
xcrun simctl install "$UDID" "$APP"
xcrun simctl status_bar "$UDID" override --time 9:41 --batteryState charged --batteryLevel 100

# launch <screen>: a fresh run of the app on that screen.
launch() {
    xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
    xcrun simctl launch "$UDID" "$BUNDLE_ID" -screen "$1" -demo 1 >/dev/null
}

shot() {
    xcrun simctl io "$UDID" screenshot "$OUT/$1.png" >/dev/null 2>&1
}

launch home
sleep 3
shot home

launch summary
sleep 3
shot summary

# The set is 8 reps at 2 s each after a 1 s lead-in: 2 s in is the start of
# the first rep, 9 s in is mid-set.
launch workout
sleep 2
shot workout_start
sleep 7
shot workout_mid

# 18 s of the workout screen from a fresh start.
xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
xcrun simctl io "$UDID" recordVideo --codec=h264 --force "$OUT/workout.mp4" >/dev/null 2>&1 &
RECORDER_PID=$!
sleep 2
launch workout
sleep 18
kill -INT "$RECORDER_PID"
wait "$RECORDER_PID" || true
RECORDER_PID=""

xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
xcrun simctl status_bar "$UDID" clear

echo
echo "wrote:"
for name in home.png workout_start.png workout_mid.png summary.png workout.mp4; do
    echo "  $OUT/$name"
done
