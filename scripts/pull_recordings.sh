#!/usr/bin/env bash
# Copy the recorder's files off a connected iPhone and sort them.
#
#   scripts/pull_recordings.sh [device-id]
#
# Pulls Documents/Recordings from the debug app (com.addymitter.pushuptime.dev)
# with `xcrun devicectl`. Session JSON files that are new go to data/sessions/,
# video files that are new go to private/video/ (never published, git-ignored).
# A file that already exists with different contents is reported as a conflict
# and skipped, never overwritten. Nothing is deleted, on the phone or here.
#
# It also pulls Documents/WorkoutLogs, the debug app's flight recorder (the
# raw frames of ordinary workouts, kind "workout"), into private/workout-logs/.
# Those are never copied into data/sessions. A phone with no WorkoutLogs folder
# is fine.
#
# device-id is a CoreDevice identifier from `xcrun devicectl list devices`. With
# no argument the single connected phone is used.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUNDLE_ID="com.addymitter.pushuptime.dev"
SESSIONS_DIR="$ROOT/data/sessions"
VIDEO_DIR="$ROOT/private/video"
WORKOUT_LOGS_DIR="$ROOT/private/workout-logs"

if ! xcrun --find devicectl >/dev/null 2>&1; then
    echo "error: xcrun devicectl not found. Install Xcode 15 or later." >&2
    exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
    echo "error: python3 is needed to read the device list and the session files." >&2
    exit 1
fi

STAGING="$(mktemp -d "${TMPDIR:-/tmp}/pull_recordings.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT

DEVICE="${1:-}"
if [ -z "$DEVICE" ]; then
    xcrun devicectl list devices --quiet --json-output "$STAGING/devices.json" >/dev/null
    # Phones that are paired and not marked unavailable, one "identifier<TAB>name" per line.
    CANDIDATES="$(python3 - "$STAGING/devices.json" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    devices = json.load(f).get("result", {}).get("devices", [])
for d in devices:
    conn = d.get("connectionProperties", {})
    hw = d.get("hardwareProperties", {})
    if hw.get("platform") != "iOS" or hw.get("deviceType", "iPhone") != "iPhone":
        continue
    if conn.get("pairingState") != "paired" or conn.get("tunnelState") == "unavailable":
        continue
    print("%s\t%s" % (d.get("identifier", ""), d.get("deviceProperties", {}).get("name", "")))
PY
)"
    COUNT=0
    if [ -n "$CANDIDATES" ]; then
        COUNT="$(printf '%s\n' "$CANDIDATES" | wc -l | tr -d ' ')"
    fi
    if [ "$COUNT" -eq 0 ]; then
        echo "error: no connected iPhone found. Connect and unlock the phone, then try again." >&2
        echo "       (xcrun devicectl list devices shows what the Mac can see.)" >&2
        exit 1
    fi
    if [ "$COUNT" -gt 1 ]; then
        echo "error: $COUNT iPhones are connected; pass the identifier of the one to use:" >&2
        printf '%s\n' "$CANDIDATES" | sed 's/^/       /' >&2
        exit 1
    fi
    DEVICE="${CANDIDATES%%$'\t'*}"
    echo "device: ${CANDIDATES#*$'\t'} ($DEVICE)"
else
    echo "device: $DEVICE"
fi

PULL="$STAGING/pull"
mkdir -p "$PULL"
if ! xcrun devicectl device copy from \
        --device "$DEVICE" \
        --domain-type appDataContainer \
        --domain-identifier "$BUNDLE_ID" \
        --source Documents/Recordings \
        --destination "$PULL" \
        --quiet; then
    echo "error: could not copy Documents/Recordings from $BUNDLE_ID." >&2
    echo "       The phone must be unlocked, and the debug app (PushupTimeDev) must be installed." >&2
    exit 1
fi

# devicectl may place the files directly in the destination or inside a
# Recordings folder there. Look for the files wherever they landed.
mkdir -p "$SESSIONS_DIR" "$VIDEO_DIR"
NEW_SESSIONS=0; OLD_SESSIONS=0; NEW_VIDEOS=0; OLD_VIDEOS=0; CONFLICTS=0

# copy_new SOURCE DESTINATION-DIR: prints new, same or conflict.
copy_new() {
    local src="$1" dir="$2"
    local dest="$dir/$(basename "$src")"
    if [ ! -e "$dest" ]; then
        cp -p "$src" "$dest"
        echo new
    elif cmp -s "$src" "$dest"; then
        echo same
    else
        echo conflict
    fi
}

# The flight recorder's workout logs, kept apart from the dataset. The folder
# does not exist until the first workout has been logged, so a failed copy is
# not an error.
WORKOUT_PULL="$STAGING/workout-logs"
mkdir -p "$WORKOUT_PULL"
if xcrun devicectl device copy from \
        --device "$DEVICE" \
        --domain-type appDataContainer \
        --domain-identifier "$BUNDLE_ID" \
        --source Documents/WorkoutLogs \
        --destination "$WORKOUT_PULL" \
        --quiet >/dev/null 2>&1; then
    mkdir -p "$WORKOUT_LOGS_DIR"
    NEW_LOGS=0; OLD_LOGS=0
    while IFS= read -r -d '' file; do
        outcome="$(copy_new "$file" "$WORKOUT_LOGS_DIR")"
        case "$outcome" in
            new) NEW_LOGS=$((NEW_LOGS + 1)) ;;
            same) OLD_LOGS=$((OLD_LOGS + 1)) ;;
            conflict) echo "conflict: $WORKOUT_LOGS_DIR/$(basename "$file") exists with different contents, skipped" ;;
        esac
    done < <(find "$WORKOUT_PULL" -type f -name 'workout_*.json' -print0)
    echo "workout logs: $NEW_LOGS new, $OLD_LOGS already present ($WORKOUT_LOGS_DIR)"
else
    echo "workout logs: none on the phone"
fi

FOUND=0
while IFS= read -r -d '' file; do
    FOUND=$((FOUND + 1))
    name="$(basename "$file")"
    case "$name" in
        *.json)
            outcome="$(copy_new "$file" "$SESSIONS_DIR")"
            case "$outcome" in
                new) NEW_SESSIONS=$((NEW_SESSIONS + 1)) ;;
                same) OLD_SESSIONS=$((OLD_SESSIONS + 1)) ;;
                conflict) CONFLICTS=$((CONFLICTS + 1)); echo "conflict: $SESSIONS_DIR/$name exists with different contents, skipped" ;;
            esac
            ;;
        *.mp4|*.mov)
            outcome="$(copy_new "$file" "$VIDEO_DIR")"
            case "$outcome" in
                new) NEW_VIDEOS=$((NEW_VIDEOS + 1)) ;;
                same) OLD_VIDEOS=$((OLD_VIDEOS + 1)) ;;
                conflict) CONFLICTS=$((CONFLICTS + 1)); echo "conflict: $VIDEO_DIR/$name exists with different contents, skipped" ;;
            esac
            ;;
    esac
done < <(find "$PULL" -type f \( -name '*.json' -o -name '*.mp4' -o -name '*.mov' \) -print0)

if [ "$FOUND" -eq 0 ]; then
    echo "No recordings were found on the phone."
    exit 0
fi

echo
echo "sessions: $NEW_SESSIONS new, $OLD_SESSIONS already present ($SESSIONS_DIR)"
echo "videos:   $NEW_VIDEOS new, $OLD_VIDEOS already present ($VIDEO_DIR)"
if [ "$CONFLICTS" -gt 0 ]; then
    echo "conflicts: $CONFLICTS skipped (same name, different contents)"
fi

# Sets and reps by subject, over the sessions that were just pulled.
echo
python3 - "$PULL" <<'PY'
import collections, json, os, sys

sets = collections.Counter()
reps = collections.Counter()
negatives = collections.Counter()
poses = collections.Counter()
unreadable = 0
for root, _, files in os.walk(sys.argv[1]):
    for name in files:
        if not name.endswith(".json"):
            continue
        try:
            with open(os.path.join(root, name)) as f:
                session = json.load(f)
            subject = session["subject"]
            kind = session["kind"]
        except (OSError, ValueError, KeyError):
            unreadable += 1
            continue
        if kind == "set":
            sets[subject] += 1
            reps[subject] += session.get("trueReps") or 0
        elif kind == "negative":
            negatives[subject] += 1
        elif kind == "pose":
            poses[subject] += 1

subjects = sorted(set(sets) | set(negatives) | set(poses))
if not subjects:
    print("No readable session files on the phone.")
else:
    print("on the phone, by subject:")
    print("  %-8s %5s %10s %10s %6s" % ("subject", "sets", "true reps", "negatives", "poses"))
    for s in subjects:
        print("  %-8s %5d %10d %10d %6d" % (s, sets[s], reps[s], negatives[s], poses[s]))
    print("  %-8s %5d %10d %10d %6d" % ("total", sum(sets.values()), sum(reps.values()), sum(negatives.values()), sum(poses.values())))
if unreadable:
    print("%d JSON file(s) could not be read and are not in the totals." % unreadable)
PY
