# Recording protocol

How the evaluation dataset is recorded. The aim is a dataset that can answer four questions honestly:

1. How often is the rep count exactly right, across lighting, distance, clothing and tempo?
2. How many reps does the counter award to things that are not valid pushups?
3. Does it ever count reps when nobody is exercising?
4. Does it still work on a person it has never seen?

Everything is recorded with the in-app recorder (Workout tab, Data collection mode, debug builds only). Only pose landmark coordinates are stored. No images or video leave the camera pipeline.

## Setup

- Phone on the floor, propped upright against something stable, front camera facing you head-on.
- Your face and both hands must be in frame at the top of the rep.
- Distance is measured roughly from the phone to your hands:

| Tag | Distance |
|---|---|
| `near` | 0.6 to 0.9 m |
| `mid` | 1.0 to 1.5 m |
| `far` | 1.8 to 2.5 m |

## What counts as a valid rep

Use this one definition for every count you type in:

- Start with arms fully extended.
- Lower until the elbows bend to at least 90 degrees (upper arms level with the floor, or lower).
- Return to full extension.
- Body stays roughly straight throughout.

A movement that misses any of these is not a valid rep and is not counted in the number you enter.

## Rules that keep the data honest

- **Count in your head and type your own number.** The recorder hides the app's count until after you save, so your number is not influenced by it.
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

Alternate `fitted` and `loose` clothing between sessions. Include at least one session each for the `knee`, `wide` and `narrow` variants if you do them.

## Other people

Each extra person adds more than extra sessions from the same person, because it allows a test on someone the model has never seen. One session each is enough.

- Give each person an anonymous subject id (`S02`, `S03`, and so on). Do not record names in the notes.
- Tell them before recording that only body landmark coordinates are stored, with no video, and that the dataset will be published openly under CC BY 4.0. Record only if they agree.

## Train and test split

The split is fixed before any model is trained and is by whole session, never by frame:

- The first sessions recorded by `S01` are the development set, used for training and for choosing thresholds.
- The last three sessions recorded by `S01` are the frozen test set.
- All sessions from other subjects are test-only.

Nothing is tuned on the test set. If it is ever used to make a decision, that is stated in the results.

## Getting the files off the phone

Either connect the phone to the Mac, or use Export all in the recorder and AirDrop the zip to the Mac. The JSON files go in `training/data/raw/`. The file format is described in `docs/data-format.md`.
