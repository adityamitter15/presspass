#!/usr/bin/env python3
"""Count the press-ups in each recorded take again, from the video alone.

Why: when a take is recorded with the app's count on screen, the person
typing the true count has seen (and heard) the app's number, so the label is
not independent of the thing being measured. This tool plays each take's
video, which has no overlay on it, and asks for a count without showing the
app's count, the count typed at the time, or the file name. The answers go to
data/recounts.json and can then be compared with the originals.

Usage:
    python3 scripts/recount.py --who "your name"

It opens each clip in QuickTime Player and waits for you to type a number.
Type r to play the clip again, s to skip it, q to stop (progress is kept and
the next run carries on where you left off).

Only takes of kind "set" are shown. Videos are read from private/video and
are never copied anywhere; only the counts are written.
"""

import argparse
import datetime
import json
import random
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

VALID_REP = """A valid press-up, the same definition used when recording:
  - starts with arms fully extended
  - lowers until the elbows bend to at least 90 degrees
  - returns to full extension
  - body stays roughly straight
Count only reps that meet all of these. Half reps and arm waves count as 0."""


def load_sessions(sessions_dir):
    """Map session file stem to the few fields this tool needs."""
    sessions = {}
    for path in sorted(sessions_dir.glob("*.json")):
        try:
            with open(path) as handle:
                doc = json.load(handle)
        except (OSError, json.JSONDecodeError) as error:
            print(f"  [skip] {path.name}: {error}")
            continue
        if doc.get("kind") != "set":
            continue
        video = (doc.get("video") or {}).get("file")
        if not video:
            continue
        sessions[path.stem] = {
            "id": doc.get("id"),
            "file": path.name,
            "video": video,
            "trueReps": doc.get("trueReps"),
            "countVisible": doc.get("countVisible"),
        }
    return sessions


def load_recounts(path):
    if not path.exists():
        return []
    with open(path) as handle:
        return json.load(handle)


def save_recounts(path, recounts):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(".json.tmp")
    with open(temporary, "w") as handle:
        json.dump(recounts, handle, indent=2, sort_keys=True)
        handle.write("\n")
    temporary.replace(path)


def play(video_path):
    subprocess.run(["open", "-a", "QuickTime Player", str(video_path)], check=False)


def ask(position, total):
    while True:
        answer = input(f"Clip {position} of {total}. Valid press-ups (number, r replay, s skip, q quit): ").strip().lower()
        if answer in ("r", "s", "q"):
            return answer
        if answer.isdigit() and 0 <= int(answer) <= 300:
            return int(answer)
        print("  Type a whole number from 0 to 300, or r, s or q.")


def summarise(sessions, recounts, who):
    mine = {entry["file"]: entry for entry in recounts if entry.get("recounter") == who}
    compared = [(sessions[Path(name).stem], entry) for name, entry in mine.items() if Path(name).stem in sessions]
    compared = [(session, entry) for session, entry in compared if session["trueReps"] is not None]
    if not compared:
        return
    agree = [pair for pair in compared if pair[0]["trueReps"] == pair[1]["recount"]]
    print()
    print(f"Counted again: {len(compared)} takes. Same as the count typed at the time: {len(agree)} ({100 * len(agree) / len(compared):.0f} percent).")
    differ = [pair for pair in compared if pair[0]["trueReps"] != pair[1]["recount"]]
    if differ:
        print("Different:")
        for session, entry in sorted(differ, key=lambda pair: pair[0]["file"]):
            visible = {True: "count was visible", False: "blind", None: "unknown"}[session["countVisible"]]
            print(f"  {session['file']}: typed {session['trueReps']}, counted again {entry['recount']} ({visible})")
        print("Watch those clips once more before deciding which number stands.")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--who", required=True, help="who is counting, stored with each answer")
    parser.add_argument("--sessions", default=str(ROOT / "data" / "sessions"), help="directory of session JSON files")
    parser.add_argument("--videos", default=str(ROOT / "private" / "video"), help="directory of take videos")
    parser.add_argument("--out", default=str(ROOT / "data" / "recounts.json"), help="where the counts are written")
    parser.add_argument("--only-visible", action="store_true", help="only takes recorded with the app's count on screen")
    parser.add_argument("--summary", action="store_true", help="print the comparison for --who and exit")
    args = parser.parse_args()

    sessions_dir, videos_dir, out_path = Path(args.sessions), Path(args.videos), Path(args.out)
    sessions = load_sessions(sessions_dir)
    recounts = load_recounts(out_path)

    if args.summary:
        summarise(sessions, recounts, args.who)
        return

    done = {entry["file"] for entry in recounts if entry.get("recounter") == args.who}
    todo = []
    for stem, session in sessions.items():
        if session["file"] in done:
            continue
        if args.only_visible and session["countVisible"] is not True:
            continue
        video_path = videos_dir / session["video"]
        if not video_path.exists():
            print(f"  [no video] {session['file']}")
            continue
        todo.append((session, video_path))

    if not todo:
        print("Nothing left to count.")
        summarise(sessions, recounts, args.who)
        return

    # A fixed shuffle per person, so a stopped run resumes in the same order
    # and the order says nothing about who or what is in a clip.
    random.Random(args.who).shuffle(todo)

    print(VALID_REP)
    print()
    print(f"{len(todo)} clips to count. Nothing about each clip is shown except the video itself.")
    print()

    for position, (session, video_path) in enumerate(todo, start=1):
        play(video_path)
        while True:
            answer = ask(position, len(todo))
            if answer == "r":
                play(video_path)
                continue
            break
        if answer == "q":
            break
        if answer == "s":
            continue
        recounts.append({
            "id": session["id"],
            "file": session["file"],
            "recount": answer,
            "recounter": args.who,
            "recountedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
        })
        save_recounts(out_path, recounts)

    remaining = len(todo) - sum(1 for session, _ in todo if any(e["file"] == session["file"] and e.get("recounter") == args.who for e in recounts))
    if remaining:
        print(f"\nStopped with {remaining} clips left. Run the same command again to carry on.")
    else:
        summarise(sessions, recounts, args.who)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\nStopped. Progress is saved.")
        sys.exit(130)
