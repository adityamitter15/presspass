# Recording data format, schema version 2

Reference for the JSON files written by the in-app recorder (Workout tab, Data collection mode, debug builds only). One file is one take. The JSON holds pose landmark coordinates and the phone's motion, never images or video. A take can also have a separate video file next to it, described by `video`, which is not part of the published dataset (see "Video").

The types are defined in `Packages/PushupCore/Sources/PushupCore/RecordedSession.swift` and `RawPoseFrame.swift`. The recording procedure is in `docs/recording-protocol.md`.

## Files

- Written to `Documents/Recordings/` in the app container, one file per take, atomically.
- File name: `<kind>_<yyyyMMdd-HHmmss>_<first 8 characters of id, lowercased>.json`, time in UTC. Example: `set_20260704-093015_3f2504e0.json`.
- "Export all" in the recorder zips the whole directory as `pushup-recordings-<yyyyMMdd-HHmmss>.zip` (UTC) for sharing.
- On the Mac, recordings live in `data/sessions/` at the repo root. The evaluation tools read that directory by default (`docs/evaluation.md`).
- Schema 1 (the earlier `label` / `source` / `joints` format) is not readable by the schema 2 loader. A file whose `schema` is not `2` is rejected with `RecordedSessionError.unsupportedSchema`.
- Absent optional values are omitted from the JSON rather than written as `null`. A reader should treat a missing key and `null` the same way.
- Size is roughly 45 to 70 kB per recorded second at 30 fps, so a take at the 300 second limit is about 14 to 20 MB. Motion adds roughly 10 to 15 kB per recorded second (100 samples of 10 numbers).
- `motion` and `video` were added without changing the schema number. A file without them is still a valid schema 2 file and loads with no motion and no video.
- `countVisible` and `editedAt` were added without changing the schema number. Files without them still load; a missing key and `null` mean the same as "unknown" and "never edited". The `knuckle` and `knuckle_knee` variants are new; a reader of the older enum would not know them.
- `hands`, `support` and `width` (under `tags`) were added without changing the schema number. They are absent in files recorded before this change, and a reader should then infer them from `variant`, see "Tags".
- Labels can be corrected after saving (the true count, subject, hands, legs, width, tempo, `cheat`, lighting, distance, clothing and notes). Saving an edit rewrites the same file atomically under the same name, changes only those fields and sets `editedAt`. The kind, `id`, `createdAt`, `device`, `live`, `frames`, `motion`, `video` and `countVisible` are written back exactly as they were.
- A take recorded with video also writes `<same base name>.mp4` in the same directory, for example `set_20260704-093015_3f2504e0.mp4`. "Export all" zips it with the rest; deleting a recording in the app deletes its video too.

## Top level

| Field | Type | Meaning |
|---|---|---|
| `schema` | integer | Always `2`. |
| `id` | string | UUID of the take. |
| `createdAt` | string | ISO 8601 in UTC, whole seconds, for example `2026-07-04T09:30:15Z`. Taken when recording started. |
| `kind` | string | `set`, `negative` or `pose`. See "Ground truth". |
| `trueReps` | integer, optional | Human-entered count of valid reps. Present for `set` and `negative`, absent for `pose`. |
| `poseLabel` | string, optional | `up`, `down` or `not_pushup`. Present only for `pose`. |
| `subject` | string | Anonymous subject id such as `S01`. Never a name. |
| `tags` | object | Recording conditions, see "Tags". |
| `notes` | string | Free text, may be empty. |
| `device` | object | See "Device". |
| `live` | object, optional | What the app counted while recording, see "Live result". |
| `frames` | array | One entry per camera frame, see "Frames". |
| `motion` | object, optional | The phone's own motion during the take, see "Motion". Absent in early files and when the device had no motion sensors. |
| `video` | object, optional | The camera video saved for the take, see "Video". Absent when no video was saved. |
| `countVisible` | boolean, optional | `true` when the app's own live count was shown on screen (and its rep sounds played) while this take was recorded, `false` for a blind take. Absent in files recorded before the recorder could show it, when the count was always hidden. |
| `editedAt` | string, optional | ISO 8601 in UTC, whole seconds. When the labels of this file were last corrected by hand in the recorder. Absent when the file has never been edited. |

## Ground truth

- `set`: a pushup set. `trueReps` is the number of valid reps the person did, typed in by them after stopping, using the definition of a valid rep in `docs/recording-protocol.md`. It can be `0` (for example a set of half reps only).
- `negative`: a clip in which nothing should count, such as holding a plank or stretching. `trueReps` is always `0`.
- `pose`: a held pose with no repetitions. There is no rep count, so `trueReps` is absent. `poseLabel` says which pose was held (`up`, `down`, `not_pushup`), matching the labels the pose classifier produces.

`trueReps` is typed in by the person after stopping, and the field always starts empty: it is never filled in from the app's count. Whether that person could see the app's count while recording depends on the take: see `countVisible`. When it is `true`, or absent in an older file, the count was on screen while recording, and the count should be checked again from the video by someone who has not seen the app's count. The recorder never shows the app's count while the number is typed; it shows it only after the take is saved.

## Tags

All values are strings. For `negative` and `pose` takes the recorder forces `tempo` to `na`, `variant` to `na` and `cheat` to `none`, and leaves `hands`, `support` and `width` out.

| Field | Values |
|---|---|
| `lighting` | `daylight`, `indoor_bright`, `dim` |
| `distance` | `near`, `mid`, `far` (phone to hands, ranges in the protocol) |
| `clothing` | `fitted`, `loose` |
| `tempo` | `slow`, `normal`, `fast`, `na` |
| `variant` | `standard`, `knuckle`, `knee`, `knuckle_knee`, `wide`, `narrow`, `na` (a derived summary, see below) |
| `hands` | `palms`, `knuckles`. Optional |
| `support` | `toes`, `knees` (what the lower body rests on, shown as Legs in the recorder). Optional |
| `width` | `normal`, `wide`, `narrow` (hand spacing). Optional |
| `cheat` | `none`, `half_reps`, `arm_wave`, `phone_moved`, `video_replay`, `other` |

### Hands, legs and width

How the press-ups were done is three independent choices, so knuckle press-ups on the knees can be recorded as such: `hands` (`palms` or `knuckles`), `support` (`toes` or `knees`) and `width` (`normal`, `wide` or `narrow`). These three fields are the precise record. They are optional: they are absent in files recorded before they were added, and for `negative` and `pose` takes, where they do not apply.

`variant` is kept so older readers and older files keep working. When the three fields are present it is a derived summary of them, chosen by the first rule that matches: `knuckles` with `knees` gives `knuckle_knee`; `knees` gives `knee`; `knuckles` gives `knuckle`; `wide` gives `wide`; `narrow` gives `narrow`; anything else gives `standard`. The recorder writes both and keeps them in agreement, including when a label is edited. The summary drops information (a wide grip on the knees is just `knee`), so use the three fields when they exist.

For a file without them, infer the three from `variant`: `standard` is palms, toes, normal; `knuckle` is knuckles, toes, normal; `knee` is palms, knees, normal; `knuckle_knee` is knuckles, knees, normal; `wide` is palms, toes, wide; `narrow` is palms, toes, narrow; `na` is treated as `standard`. `PushupCore` does this in `RecordedSession.Tags.resolved`.

## Device

| Field | Meaning |
|---|---|
| `model` | Hardware identifier, for example `iPhone17,2`. |
| `systemVersion` | OS version, for example `26.0`. |
| `appVersion`, `appBuild` | `CFBundleShortVersionString` and `CFBundleVersion` of the app that recorded the take. |
| `poseModel` | Detector asset, currently `pose_landmarker_full` (MediaPipe BlazePose Full). |
| `cameraPosition` | Camera used, currently `front`. |
| `featureVersion` | Version of the feature contract in force when recorded, currently `v1`. |

## Live result

`live` is the result of the app's own counting pipeline (`PushupPipeline`) run on the frames as they arrived, taken after the last recorded frame. It is stored next to the true count so the two can be compared. It describes the app build named in `device`, not any later version.

| Field | Meaning |
|---|---|
| `reps` | Reps the app counted. |
| `rejectedReps` | Rep attempts the app rejected for coming too soon after the previous one. |
| `classifier` | `heuristic` or `coreml`: which pose classifier was active. |

`live` was never shown while `trueReps` was typed. During recording it was shown only if `countVisible` is `true`.

## Frames

Each element of `frames` is one camera frame the detector ran on, in order. A frame the pose detector could not process is still recorded, with no landmarks.

| Field | Type | Meaning |
|---|---|---|
| `t` | number | Seconds since the first recorded frame, from the clock the live pipeline uses for its own timestamps. The first frame has `t` of `0`. This is the time to replay with. |
| `pts` | number, optional | Seconds since the first recorded frame, from the camera's presentation timestamp. Absent if the camera gave none. |
| `lm` | array of 165 numbers, optional | Image landmarks, see below. Absent when no body was detected. |
| `wlm` | array of 99 numbers, optional | World landmarks, see below. Absent when the detector gave none. |

`t` and `pts` advance at about the camera frame rate (typically 30 per second) but are not exactly regular. Frames that the camera session dropped are not present.

A reader must treat an `lm` whose length is not 165, or a `wlm` whose length is not 99, as absent. The loader in `PushupCore` does this.

### Landmark order

Both arrays hold the 33 BlazePose landmarks in the order defined on the official MediaPipe pose landmarker page: https://ai.google.dev/edge/mediapipe/solutions/vision/pose_landmarker

| Index | Landmark | Index | Landmark | Index | Landmark |
|---|---|---|---|---|---|
| 0 | nose | 11 | left shoulder | 22 | right thumb |
| 1 | left eye (inner) | 12 | right shoulder | 23 | left hip |
| 2 | left eye | 13 | left elbow | 24 | right hip |
| 3 | left eye (outer) | 14 | right elbow | 25 | left knee |
| 4 | right eye (inner) | 15 | left wrist | 26 | right knee |
| 5 | right eye | 16 | right wrist | 27 | left ankle |
| 6 | right eye (outer) | 17 | left pinky | 28 | right ankle |
| 7 | left ear | 18 | right pinky | 29 | left heel |
| 8 | right ear | 19 | left index | 30 | right heel |
| 9 | mouth (left) | 20 | right index | 31 | left foot index |
| 10 | mouth (right) | 21 | left thumb | 32 | right foot index |

The app's pipeline uses indices 0, 11 to 16 and 23 to 28.

### `lm`: image landmarks

Flat array, 5 values per landmark, landmark `i` at offset `i * 5`:

`[x, y, z, visibility, presence]`

- `x`, `y`: normalised to the image width and height. The origin is the top-left corner and `y` increases downward, which is the BlazePose convention. This is the opposite of the app's internal `PoseFrame` (origin bottom-left, `y` up); `BlazePoseMapping` flips it. Values can fall slightly outside 0 to 1 for landmarks the model places off-image.
- The image is the portrait, front-camera frame as the app uses it (mirrored, so the person's left is on the left of the image).
- `z`: depth with the hip midpoint as origin, on roughly the same scale as `x`. Smaller is closer to the camera.
- `visibility`: likelihood, 0 to 1, that the landmark is visible and not occluded.
- `presence`: likelihood, 0 to 1, that the landmark is present in the image.
- A visibility or presence the detector did not report is stored as `-1`. This is the only use of `-1`; real values are never negative.

### `wlm`: world landmarks

Flat array, 3 values per landmark, landmark `i` at offset `i * 3`:

`[x, y, z]`

Metres, in a real-world 3D frame whose origin is approximately the hip midpoint. There is no visibility or presence for world landmarks.

### Rounding

Values are rounded when written, so the JSON stays short:

| Value | Decimal places |
|---|---|
| `lm` x, y, z | 6 |
| `lm` visibility, presence | 4 |
| `wlm` x, y, z | 5 |
| `t`, `pts` | 6 |

A frame holding any non-finite number, or a landmark array that is not 33 long, is stored without that array.

## Motion

`motion` holds the phone's own motion while the take was recording, so later analysis can tell whether the phone was moved and whether a phone resting on the floor can sense a pushup through the floor. It comes from Core Motion's device motion, which needs no permission.

| Field | Type | Meaning |
|---|---|---|
| `rateHz` | number | The update rate that was requested, `100`. The real spacing varies, so use `t` rather than assuming a fixed step. |
| `samples` | array of numbers | Flat array, 10 values per sample. Sample `i` starts at offset `i * 10`. |

Each sample is:

`[t, ax, ay, az, rx, ry, rz, gx, gy, gz]`

| Values | Source | Unit |
|---|---|---|
| `t` | Sample time on the pose timeline, see below | seconds |
| `ax`, `ay`, `az` | `CMDeviceMotion.userAcceleration`, acceleration with gravity removed | g |
| `rx`, `ry`, `rz` | `CMDeviceMotion.rotationRate` | rad/s |
| `gx`, `gy`, `gz` | `CMDeviceMotion.gravity`, the gravity vector | g |

- Axes are Core Motion's device reference frame: x to the right of the screen, y towards the top of the screen, z out of the screen, fixed to the phone whatever its orientation. See Apple's documentation: https://developer.apple.com/documentation/coremotion/cmdevicemotion and https://developer.apple.com/documentation/coremotion/cmattitude
- `t` is on the same timeline as `frames[].pts`: seconds since the presentation time of the first recorded frame. The camera presentation timestamps and `CMDeviceMotion.timestamp` are both host-clock seconds since boot, so they are directly comparable. Do not mix `t` with `frames[].t`, which is a different clock.
- A sample taken between pressing Start and the first frame arriving has a small negative `t`.
- Samples are in time order. A reader must count whole samples only: `samples.count / 10` rounded down, ignoring a trailing partial sample. `PushupCore` does this in `MotionStream.sampleCount`.
- Rounding: `t` to 6 decimal places, the nine sensor values to 5.
- `motion` is omitted when the device has no motion sensors (including the simulator) or when the first recorded frame had no presentation time, since the timelines then cannot be aligned.

## Video

`video` describes the camera video that was saved for the take. The video exists so the same repetitions can later be shown to other counting systems for comparison. The video files are **not part of the dataset**: they are never committed to the repository, never published, and are kept outside the dataset (on the Mac, in `private/video/`, which is git-ignored; `data/sessions/*.mp4` and `*.mov` are git-ignored too). Only participants who agreed to video are recorded with it, and it can be switched off per take in the recorder.

| Field | Type | Meaning |
|---|---|---|
| `file` | string | File name only, no path: the session's file name with `.json` replaced by `.mp4`. |
| `width`, `height` | integer | Encoded size in pixels. Portrait, at most 720 by 1280, even numbers. |
| `codec` | string | `h264`. MP4 container, no audio track. |
| `frameCount` | integer | Frames written to the file. Can be lower than `frames.count`: see "Alignment". |
| `startPts` | number | Presentation time of the video's first frame minus the presentation time of the first recorded frame, in seconds, rounded to 6 decimals. Can be slightly negative or positive. |

Alignment. The video holds the same camera frames the pose detector saw, portrait and mirrored exactly as for `lm`, so a landmark can be drawn on its video frame without any transform. A recorded frame with `pts` of `p` appears in the video at time

`p - startPts`

seconds (video time 0 is the video's first frame). A result below 0, or at or beyond the video's duration, means that frame has no video frame: the video can start a frame or two after the first recorded frame, and ends with the last frame of the take. The video clock and `pts` are the same camera clock, so `startPts` is the only offset needed. Do not use `frames[].t` for this. The video is about 4 Mbit per second, so roughly 0.5 MB per recorded second.

`video` is omitted when no video was saved: video switched off, a device or simulator with no camera, a video that could not be written, or a first frame with no presentation time, which leaves nothing to align against.

## Replaying a take

`RecordedSession.load(from:)` reads a file and `poseFrames()` maps every frame to a `PoseFrame` with `BlazePoseMapping.poseFrame(from:)`. A frame without `lm` maps to a frame with no joints. Feeding those to a fresh `PushupPipeline` with the same classifier gives the same counting path the app ran live; compare its `reps` with `trueReps`, and with `live.reps` to check the replay matches what the app showed. Landmarks with visibility below 0.1 are dropped by the mapping, as they are live.

## Example

A minimal document (the landmark arrays are shortened here for reading; real ones have 165 and 99 numbers, and real `motion.samples` holds one sample every 10 ms or so, not two):

```json
{
  "schema": 2,
  "id": "3F2504E0-4F89-41D3-9A0C-0305E82C3301",
  "createdAt": "2026-07-04T09:30:15Z",
  "kind": "set",
  "trueReps": 12,
  "subject": "S01",
  "tags": {
    "lighting": "indoor_bright",
    "distance": "mid",
    "clothing": "fitted",
    "tempo": "normal",
    "variant": "standard",
    "cheat": "none",
    "hands": "palms",
    "support": "toes",
    "width": "normal"
  },
  "notes": "",
  "device": {
    "model": "iPhone17,2",
    "systemVersion": "26.0",
    "appVersion": "1.0",
    "appBuild": "1",
    "poseModel": "pose_landmarker_full",
    "cameraPosition": "front",
    "featureVersion": "v1"
  },
  "live": { "reps": 11, "rejectedReps": 0, "classifier": "heuristic" },
  "frames": [
    { "t": 0, "pts": 0, "lm": [0.512345, 0.231234, -0.150001, 0.9876, 0.9991, "..."], "wlm": [0.01234, -0.5421, 0.0987, "..."] },
    { "t": 0.033412, "pts": 0.033333 }
  ],
  "motion": {
    "rateHz": 100,
    "samples": [
      -0.004211, 0.00123, -0.00457, 0.00089, 0.0102, -0.0033, 0.0007, 0.01234, -0.98765, -0.15432,
      0.005789, 0.00131, -0.00449, 0.00091, 0.0098, -0.0035, 0.0006, 0.01236, -0.98764, -0.15433
    ]
  }
}
```
