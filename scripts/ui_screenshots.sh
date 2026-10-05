#!/usr/bin/env bash
# Builds the Dev app for the iPhone 17 Pro simulator (iOS 26.5), runs it on
# the replayed demo session, and saves screenshots and a 20 second video of
# the home, workout, summary, settings and data recorder screens. No camera or device
# needed. Every launch is muted. Pinned HUD states (-debugState) stand in for
# moments the replay does not reach on cue.
#
# usage: scripts/ui_screenshots.sh [output-dir]     (default build/ui-shots)
set -euo pipefail

cd "$(dirname "$0")/.."
OUT="${1:-build/ui-shots}"
# SIM_NAME and SIM_OS pick another simulator, for example SIM_NAME="iPhone 16 Pro"
# SIM_OS=18.6 to check the non-Liquid-Glass look. DEMO_BACKDROP, an absolute
# path to a still camera frame, is shown behind the skeleton in every workout shot.
DEVICE_NAME="${SIM_NAME:-iPhone 17 Pro}"
SIM_OS="${SIM_OS:-26.5}"
RUNTIME="com.apple.CoreSimulator.SimRuntime.iOS-${SIM_OS//./-}"
DEMO_BACKDROP="${DEMO_BACKDROP:-}"
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

# wlaunch <args...>: launch for a workout shot, with the backdrop when one is set.
wlaunch() {
    if [[ -n "$DEMO_BACKDROP" ]]; then
        launch "$@" -demoBackdrop "$DEMO_BACKDROP"
    else
        launch "$@"
    fi
}

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
wlaunch -screen workout -debugState positioning
sleep 3
shot workout_positioning

wlaunch -screen workout
sleep 4.5
shot workout_active_1
sleep 5
shot workout_active_2

wlaunch -screen workout -debugState shallow
sleep 3
shot workout_shallow

wlaunch -screen workout -debugState finishing
sleep 3
shot workout_finishing

wlaunch -screen workout -debugState nobody
sleep 3
shot workout_nobody

wlaunch -screen summary
sleep 3.5
shot summary

launch -screen settings
sleep 3
shot settings

# The data recorder, stage by stage. Its setup is pinned by the launch
# arguments (subject S07, knuckle, shown count unless -recorderCount 0), and
# -demoRecordings 1 gives it three in-memory takes so nothing is written.
# The recorder opens about 0.35 s after launch; a take starts 1.2 s after it
# opens and the label shot stops it 6 s later.
wlaunch -screen recorder -demoRecordings 1
sleep 3
shot recorder_setup

wlaunch -screen recorder -demoRecordings 1 -recorderScroll end
sleep 3.5
shot recorder_setup_lower

wlaunch -screen recorder -demoRecordings 1 -recorderCheat half_reps -recorderScroll take
sleep 3.5
shot recorder_setup_cheat

wlaunch -screen recorder-recording -demoRecordings 1
sleep 6
shot recorder_recording

wlaunch -screen recorder-recording -demoRecordings 1 -recorderCount 0
sleep 6
shot recorder_recording_blind

wlaunch -screen recorder-label -demoRecordings 1
sleep 10
shot recorder_label

wlaunch -screen recorder-list -demoRecordings 1
sleep 3.5
shot recorder_list

wlaunch -screen recorder-list -demoRecordings 1 -recorderEdit 1
sleep 4.5
shot recorder_edit

# 20 s of the live workout from a fresh start.
xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
xcrun simctl io "$UDID" recordVideo --codec=h264 --force "$OUT/workout.mp4" >/dev/null 2>&1 &
RECORDER_PID=$!
sleep 2
wlaunch -screen workout
sleep 20
kill -INT "$RECORDER_PID"
wait "$RECORDER_PID" || true
RECORDER_PID=""

xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
xcrun simctl status_bar "$UDID" clear

echo
echo "wrote:"
for name in home_empty.png home.png workout_positioning.png workout_active_1.png workout_active_2.png \
    workout_shallow.png workout_finishing.png workout_nobody.png summary.png settings.png \
    recorder_setup.png recorder_setup_lower.png recorder_setup_cheat.png recorder_recording.png \
    recorder_recording_blind.png recorder_label.png recorder_list.png recorder_edit.png workout.mp4; do
    echo "  $OUT/$name"
done
