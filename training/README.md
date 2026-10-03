# Pushup pose classifier -- training pipeline

Standalone Python pipeline that trains a frame classifier (`up` / `down` /
`not_pushup`) on body-pose landmarks recorded by the iOS app, and exports
it to Core ML for on-device inference.

## Setup

```bash
cd training
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

Tested with Python 3.9-3.12. If venv creation fails on macOS with a
`pyexpat` / `libexpat` symbol error, it means the Python you pointed at is
a Homebrew build linked against a newer `libexpat` than the one macOS
ships at `/usr/lib/libexpat.1.dylib` -- use a different Python (e.g. the
Xcode Command Line Tools' `/usr/bin/python3`, or a fresh
`brew reinstall python@3.12` if you're able to touch system state) and
retry.

## 1. Recording data (contract for the iOS app)

Each recording session is written as one JSON file under `data/raw/`:

```json
{
  "label": "up",
  "source": "iPhone 14 Pro, back camera, Aditya, 2026-07-14",
  "frames": [
    {
      "t": 0.033,
      "joints": {
        "leftShoulder": [0.41, 0.32, 0.97],
        "rightShoulder": [0.59, 0.31, 0.95],
        "...": "one [x, y, confidence] triple per joint"
      }
    }
  ]
}
```

- `label` is one of `"up"`, `"down"`, `"not_pushup"` -- the whole session
  gets one label (record a separate session per pose/position, not a full
  pushup rep that moves through both).
- `source` is free text -- device, person, anything useful for debugging
  a bad session later. Not used by training.
- `frames` is an ordered list; `t` is seconds since the session started;
  `joints` maps joint name -> `[x, y, confidence]`, `x`/`y` normalized to
  `[0, 1]` in image coordinates, `confidence` in `[0, 1]`.
- Recognized joint names (Apple Vision `VNHumanBodyPoseObservation`
  subset): `nose, neck, leftShoulder, rightShoulder, leftElbow,
  rightElbow, leftWrist, rightWrist, leftHip, rightHip, root, leftKnee,
  rightKnee, leftAnkle, rightAnkle`. A joint can simply be omitted from a
  frame if Vision didn't detect it.

Aim for a mix of people, camera angles/distances, and lighting per class,
and a good number of `not_pushup` sessions (standing, sitting, walking,
stretching, etc.) so the classifier learns what a pushup is *not*.

## 2. Try it end-to-end with synthetic data

Before any real recordings exist, generate a synthetic dataset so you can
run the whole pipeline and sanity-check it works:

```bash
python make_synthetic.py --out data/raw --per-class 10
python train.py --data data/raw --out models/
python evaluate.py --data data/raw --out models/
```

Synthetic data is easy (clean, parametric poses), so expect test accuracy
well above 90%. Delete the synthetic files from `data/raw/` before adding
real recordings, or keep them around as an easy regression check --
they're prefixed `synthetic_*.json` so they're easy to find and remove:

```bash
rm data/raw/synthetic_*.json
```

## 3. Train

```bash
python train.py --data data/raw --out models/
```

What it does:
1. Loads every session under `--data`, extracts a 25-dim feature vector
   per frame via `features.py` (frames that fail the confidence gate are
   dropped).
2. Splits **sessions** (not frames) 80/20 into train/test, stratified by
   label, so frames from one recording never appear on both sides.
3. Trains a k-NN (k=10, distance-weighted) and a small MLP (one hidden
   layer, 32 units), and reports test accuracy for both.
4. Exports the more accurate one to `models/PushupPoseClassifier.mlmodel`
   (Core ML input: `pose_features`, a `MultiArray` of 25 floats; outputs:
   `label` + `labelProbability`). If the winner is k-NN and it can't be
   exported cleanly (see `coreml_export.py` for why that happens with
   distance-weighted k-NN and this coremltools version), the MLP is
   exported instead and this is noted in `metadata.json`.
5. Writes `models/metadata.json` (train date, feature version, per-class
   counts, both models' test accuracy, which one got exported) and
   pickles both trained sklearn models (`models/knn_model.pkl`,
   `models/mlp_model.pkl`) so `evaluate.py` doesn't need to retrain.

## 4. Evaluate

```bash
python evaluate.py --data data/raw --out models/
```

Reproduces the exact same train/test split as `train.py` (same seed and
test_size, read from `metadata.json`), loads the exported model's pickled
sklearn twin, and prints per-class precision/recall/F1 on the held-out
test frames plus saves `models/confusion_matrix.png`.

## 5. Ship the model to the iOS app

Copy the exported model into the app's bundle and re-point Xcode at it:

```bash
cp models/PushupPoseClassifier.mlmodel ../App/PushupPoseClassifier.mlmodel
```

(adjust the destination path to wherever the app project expects it --
check the existing model reference in the Xcode project if one is already
wired up). Then rebuild the app.

**If you changed `features.py`**, bump `FEATURE_VERSION` at the top of
that file and mirror the exact same normalization/feature logic in the
Swift feature extractor before shipping the new model -- a model trained
on v2 features will produce garbage predictions if fed v1 features (or
vice versa).

## Iterating

The expected loop as more data comes in:

```bash
# record more sessions into data/raw/ from the app
python train.py --data data/raw --out models/
python evaluate.py --data data/raw --out models/
# check models/metadata.json + models/confusion_matrix.png
cp models/PushupPoseClassifier.mlmodel ../App/PushupPoseClassifier.mlmodel
```

## Files

- `features.py` -- the feature extractor (single source of truth; mirror
  it in Swift)
- `dataset.py` -- shared session loading + session-stratified split logic
  used by both `train.py` and `evaluate.py`
- `coreml_export.py` -- Core ML export for the k-NN and MLP models
- `train.py` -- trains both models, exports the winner, writes metadata
- `evaluate.py` -- confusion matrix + per-class precision/recall on the
  held-out split
- `make_synthetic.py` -- generates synthetic sessions so the pipeline
  runs end-to-end before real data exists
- `data/raw/` -- session JSON files live here (gitignored except
  `.gitkeep`)
