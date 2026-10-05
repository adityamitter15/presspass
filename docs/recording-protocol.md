# Recording protocol

How the evaluation dataset is recorded. The aim is a dataset that can answer four questions honestly:

1. How often is the rep count exactly right, across lighting, distance, clothing and tempo?
2. How many reps does the counter award to things that are not valid pushups?
3. Does it ever count reps when nobody is exercising?
4. Does it still work on a person it has never seen?

Everything is recorded with the in-app recorder (the Record data button on Home, or Data collection mode in Settings, debug builds only). The dataset itself holds only pose landmark coordinates and phone motion. Video, when saved, is kept privately and is not part of the dataset (see "Video" in `docs/data-format.md`).

## Setup

- Phone on the floor, propped upright against something stable, front camera facing you head-on.
- Your face and both hands must be in frame at the top of the rep.
- Choose the person's label (S01, S02 and so on) under Person; Next person steps it on. Each take is labelled in the sheet that opens after Stop, and a saved take can be corrected afterwards from Saved takes (tap it to edit the count and tags).
- The recorder saves the camera video of each take for participants who agreed to it. Switch Save video off in Setup for anyone who did not, or for any single take.
- Distance is measured roughly from the phone to your hands:

| Tag | Distance |
|---|---|
| `near` | 0.6 to 0.9 m |
| `mid` | 1.0 to 1.5 m |
| `far` | 1.8 to 2.5 m |

Hold the top position (arms extended) for two seconds before the first rep and for a second after the last, so the take shows a clean start and finish. Start and stop the take by hand: the recording should include you getting into position and getting up.

Once a take has started, do not touch or move the phone until you stop it, except in the `phone_moved` cheat takes: the recorder also stores the phone's own motion, and a knock or a nudge would show up in it. Note what kind of floor the session is on in the notes field (for example carpet, wooden floorboards, concrete, yoga mat), because floor type matters for the motion data.

## What counts as a valid rep

Use this one definition for every count you type in:

- Start with arms fully extended.
- Lower until the elbows bend to at least 90 degrees (upper arms level with the floor, or lower).
- Return to full extension.
- Body stays roughly straight throughout.

A movement that misses any of these is not a valid rep and is not counted in the number you enter.

## Rules that keep the data honest

- **Count in your head and type your own number.** The count box starts empty and is never filled in from the app's count. The recorder can show the app's count while you record or hide it (Show count while recording in Options), and each take records which. A take recorded with the count visible is a take where you may have been influenced by it, so those counts are checked again from the video by someone who has not seen the app's count. Use a blind take (count hidden) whenever the person's own count must stand on its own.
- **Never discard a take because the app got it wrong.** Those takes are the most valuable ones. Discard only when you lost count or were interrupted.
- **Vary the number of reps per set** (anything from 3 to 15). Short sets keep your count reliable.
- **Change one thing per session, not per take.** A session is one sitting in one place: one lighting, one distance, one outfit.

## One session (about 10 to 15 minutes)

| # | Kind | What to do | Tags | Count to enter |
|---|---|---|---|---|
| 1 | Held pose | Hold the top position for 15 s | label `up` | none |
| 2 | Held pose | Hold the bottom position for 5 to 10 s | label `down` | none |
| 3 | Held pose | Stand or sit in frame for 15 s | label `not_pushup` | none |
| 4 to 7 | Set | Four normal sets with different rep counts | tempo `normal` | valid reps |
| 8 | Set | One slow set, about 4 s per rep | tempo `slow` | valid reps |
| 9 | Set | One fast set, full range, as quick as you can | tempo `fast` | valid reps |
| 10 | Set | Half reps only | cheat `half_reps` | 0 |
| 11 | Set | A few valid reps mixed with a few half reps | cheat `half_reps` | valid reps only |
| 12 | Set | One other cheat, a different one each session (see below) | matching cheat tag | 0 |
| 13 to 14 | Negative | Two clips of 20 s with no pushups (see below) | describe in notes | fixed at 0 |

"This take is" in the recorder resets to real press-ups after every take, saved or discarded, so a cheat tag is never carried to the next take by accident. Check it at Start: when the take is a cheat or a negative the Start button and the banner above it turn amber.

Cheats to rotate through at step 12:

- `arm_wave`: stand or kneel in frame and bend and straighten your arms.
- `phone_moved`: stay still and move the phone towards and away from you.
- `video_replay`: point the phone at a screen playing a video of someone doing pushups.
- `other`: anything else you think might fool it. Say what it was in the notes.

Negatives to rotate through at steps 13 and 14:

- Holding a plank without moving.
- Getting down into position and standing back up, several times.
- Stretching on the floor (cobra or downward dog are deliberately hard cases).
- Sitting in frame using another device.
- Walking through the frame, or picking the phone up and putting it back.

## Coverage targets

| | Sessions | Valid sets | Valid reps (approx.) |
|---|---|---|---|
| Minimum | 5 | 30 | 250 |
| Target | 10 | 60 | 500 |

Spread sessions across the conditions below. One combination per session is enough; the minimum plan should include at least one `dim` session and one `far` session, since those are where failures are expected.

| | `near` | `mid` | `far` |
|---|---|---|---|
| `daylight` | | | |
| `indoor_bright` | | | |
| `dim` | | | |

Alternate `fitted` and `loose` clothing between sessions. Knuckle and knee press-ups are accepted as long as they are tagged. They are chosen independently under Hands (palms or knuckles) and Legs (toes or knees) before Start, and can be combined, so knuckle press-ups on the knees are Knuckles plus Knees. Hand spacing is chosen under Width. Count a rep as valid under the same definition as any other. Include at least one session each for knuckles, knees, wide and narrow if you do them, and one with knuckles and knees together if anyone does that.

## Other people

Each extra person adds more than extra sessions from the same person, because it allows a test on someone the model has never seen. One session each is enough.

- Give each person an anonymous subject id (`S02`, `S03`, and so on). Do not record names in the notes.
- Go through `docs/participant-consent.md` with them before recording. The body landmark coordinates go in the openly published dataset (CC BY 4.0); video is kept privately and is saved only if they agreed to it. Record only if they agree, and switch Save video off if they said no to video.

## Train and test split

The split is fixed before any model is trained and is by whole session, never by frame:

- The first sessions recorded by `S01` are the development set, used for training and for choosing thresholds.
- The last three sessions recorded by `S01` are the frozen test set.
- All sessions from other subjects are test-only.

Nothing is tuned on the test set. If it is ever used to make a decision, that is stated in the results.

## Getting the files off the phone

Connect the phone to the Mac, unlock it, and run:

```
scripts/pull_recordings.sh [device-id]
```

It copies `Documents/Recordings` from the debug app with `xcrun devicectl` (the device id is optional when exactly one iPhone is connected). New session JSON files go into `data/sessions/` at the repo root and new video files into `private/video/`, which is git-ignored and never published. A file that already exists with different contents is reported and skipped, never overwritten, and nothing is deleted on the phone or the Mac. It prints how many files were new and the sets and reps by subject. See `docs/evaluation.md` for what to run next, and `docs/data-format.md` for the file format.

Export all in the recorder and AirDrop is the fallback; it zips the videos too, so the archive can be large. Put the JSON files in `data/sessions/` and the `.mp4` files in `private/video/`.
