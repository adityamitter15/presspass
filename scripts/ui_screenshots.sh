#!/usr/bin/env bash
# Builds the Dev app for the iPhone 17 Pro simulator (iOS 26.5), runs it on
# the replayed demo session, and saves screenshots and a 20 second video of
# the home, workout, summary and settings screens. No camera or device
# needed. Every launch is muted. Pinned HUD states (-debugState) stand in for
# moments the replay does not reach on cue.
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
# A clean install, so no history or settings from an earlier run leak in.
xcrun simctl uninstall "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
xcrun simctl install "$UDID" "$APP"
xcrun simctl status_bar "$UDID" override --time 9:41 --batteryState charged --batteryLevel 100

# launch <args...>: a fresh run of the app with those launch arguments, muted,
# on the replayed demo session, with a known number of banked minutes.
launch() {
    xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
    xcrun simctl launch "$UDID" "$BUNDLE_ID" -demo 1 -mute 1 -demoBalance 14 "$@" >/dev/null
}

shot() {
    xcrun simctl io "$UDID" screenshot "$OUT/$1.png" >/dev/null 2>&1
}

# Home, with nothing earned yet and then with a few days of passes.
launch -screen home -demoHistory 0
sleep 3
shot home_empty

launch -screen home -demoHistory 1
sleep 3
shot home

# The workout. The cover opens about 0.35 s after launch and the replay starts
# with it, so the sleeps below count from the start of the replay plus about
# 1.5 s of launch.
launch -screen workout -debugState positioning
sleep 3
shot workout_positioning

launch -screen workout
sleep 4.5
shot workout_active_1
sleep 5
shot workout_active_2

launch -screen workout -debugState shallow
sleep 3
shot workout_shallow

launch -screen workout -debugState finishing
sleep 3
shot workout_finishing

launch -screen workout -debugState nobody
sleep 3
shot workout_nobody

launch -screen summary
sleep 3.5
shot summary

launch -screen settings
sleep 3
shot settings

# 20 s of the live workout from a fresh start.
xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
xcrun simctl io "$UDID" recordVideo --codec=h264 --force "$OUT/workout.mp4" >/dev/null 2>&1 &
RECORDER_PID=$!
sleep 2
launch -screen workout
sleep 20
kill -INT "$RECORDER_PID"
wait "$RECORDER_PID" || true
RECORDER_PID=""

xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
xcrun simctl status_bar "$UDID" clear

echo
echo "wrote:"
for name in home_empty.png home.png workout_positioning.png workout_active_1.png workout_active_2.png \
    workout_shallow.png workout_finishing.png workout_nobody.png summary.png settings.png workout.mp4; do
    echo "  $OUT/$name"
done
