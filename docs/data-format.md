# Recording data format, schema version 2

Reference for the JSON files written by the in-app recorder (Workout tab, Data collection mode, debug builds only). One file is one take. Only pose landmark coordinates are stored: no images and no video.

The types are defined in `Packages/PushupCore/Sources/PushupCore/RecordedSession.swift` and `RawPoseFrame.swift`. The recording procedure is in `docs/recording-protocol.md`.

## Files

- Written to `Documents/Recordings/` in the app container, one file per take, atomically.
- File name: `<kind>_<yyyyMMdd-HHmmss>_<first 8 characters of id, lowercased>.json`, time in UTC. Example: `set_20260704-093015_3f2504e0.json`.
- "Export all" in the recorder zips the whole directory as `pushup-recordings-<yyyyMMdd-HHmmss>.zip` (UTC) for sharing.
- On the Mac, recordings live in `data/sessions/` at the repo root. The evaluation tools read that directory by default (`docs/evaluation.md`).
- Schema 1 (the earlier `label` / `source` / `joints` format) is not readable by the schema 2 loader. A file whose `schema` is not `2` is rejected with `RecordedSessionError.unsupportedSchema`.
- Absent optional values are omitted from the JSON rather than written as `null`. A reader should treat a missing key and `null` the same way.
- Size is roughly 45 to 70 kB per recorded second at 30 fps, so a take at the 300 second limit is about 14 to 20 MB.

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

## Ground truth

- `set`: a pushup set. `trueReps` is the number of valid reps the person did, typed in by them after stopping, using the definition of a valid rep in `docs/recording-protocol.md`. It can be `0` (for example a set of half reps only).
- `negative`: a clip in which nothing should count, such as holding a plank or stretching. `trueReps` is always `0`.
- `pose`: a held pose with no repetitions. There is no rep count, so `trueReps` is absent. `poseLabel` says which pose was held (`up`, `down`, `not_pushup`), matching the labels the pose classifier produces.

`trueReps` is entered by a person who could not see the app's count. The recorder hides it while recording and while the number is typed, and shows it only after the take is saved.

## Tags

All values are strings. For `negative` and `pose` takes the recorder forces `tempo` to `na`, `variant` to `na` and `cheat` to `none`.

| Field | Values |
|---|---|
| `lighting` | `daylight`, `indoor_bright`, `dim` |
| `distance` | `near`, `mid`, `far` (phone to hands, ranges in the protocol) |
| `clothing` | `fitted`, `loose` |
| `tempo` | `slow`, `normal`, `fast`, `na` |
| `variant` | `standard`, `knee`, `wide`, `narrow`, `na` |
| `cheat` | `none`, `half_reps`, `arm_wave`, `phone_moved`, `video_replay`, `other` |

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

`live` was hidden from the person while they entered `trueReps`.

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

## Replaying a take

`RecordedSession.load(from:)` reads a file and `poseFrames()` maps every frame to a `PoseFrame` with `BlazePoseMapping.poseFrame(from:)`. A frame without `lm` maps to a frame with no joints. Feeding those to a fresh `PushupPipeline` with the same classifier gives the same counting path the app ran live; compare its `reps` with `trueReps`, and with `live.reps` to check the replay matches what the app showed. Landmarks with visibility below 0.1 are dropped by the mapping, as they are live.

## Example

A minimal document (the landmark arrays are shortened here for reading; real ones have 165 and 99 numbers):

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
    "cheat": "none"
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
  ]
}
```
