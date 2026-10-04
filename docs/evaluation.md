# Evaluation harness

Offline evaluation of the pushup counter on recorded sessions. There are no real recordings yet, so no results are reported here. The harness has only been run on synthetic sessions, which exercise the code and say nothing about accuracy.

## What it does

1. `pushup-eval` (a Swift command-line tool in `Packages/PushupCore`) loads recorded sessions (`docs/data-format.md`), replays every frame through `PushupPipeline` and writes the counts to `predictions.json`.
2. A small Python package in `eval/` (`pushup_report`) reads `predictions.json` and writes metrics, tables and figures.

Replay runs the shipped Swift pipeline: the same `PushupPipeline`, `BlazePoseMapping`, `PushupFeatureExtractor`, classifier and `RepCounter` that the app runs. There is no separate offline implementation to drift from the app. The Python side never re-implements the landmark mapping or the features; it only reads the tool's output. For model training, `pushup-eval features` writes the per-frame features as CSV, so Python gets them from the same Swift code.

## Running it

On recorded data (put the JSON files in `data/sessions/`):

```
scripts/eval.sh [data-dir] [out-dir]     # defaults: data/sessions and results
```

It builds the tool in release mode, replays the sessions, writes dev/test splits and writes the report into the output directory. It exits 1 with a message if the data directory holds no session files.

As a smoke test on synthetic data (writes only into a temporary directory):

```
scripts/eval_synthetic.sh
```

The pieces, if you want to run them by hand:

```
swift build -c release --package-path Packages/PushupCore --product pushup-eval
pushup-eval replay   --data <dir> --out <predictions.json> [--config <config.json>] [--model <compiled .mlmodelc path>]
pushup-eval features --data <dir> --out <features.csv>     [--config <config.json>]
pushup-eval synth    --out <dir> [--seed <int>]
uv run --project eval python -m pushup_report.make_splits --predictions <json> --out <splits.json>
uv run --project eval python -m pushup_report.report --predictions <json> --out <dir> [--splits <json>] [--title <str>]
uv run --project eval pytest eval/tests
```

Exit codes of `pushup-eval`: 0 success, 1 runtime failure, 2 usage error.

### Replay details

- Every `*.json` file directly inside the data directory is loaded, sorted by file name. A file that cannot be decoded, or whose schema is not 2, is skipped with a warning on stderr and listed under `skipped` in the output.
- Each session gets a fresh pipeline. The default classifier is the heuristic. With `--model` the compiled Core ML model is used instead, and the tool exits non-zero if it cannot load.
- Per session the output records `predictedReps`, `rejectedReps`, `repTimes` (the frame time at which each counted rep was registered), the frame count, duration, mean frame rate, and `frameCounts`: how many frames had no body (`noBody`), failed the feature gate (`featuresNil`), failed the joint confidence check (`lowConfidence`), failed the posture gate (`notInPosture`) or reached the state machine (`processed`). The five add up to the frame count.
- The output has no wall-clock data: the same inputs give the same bytes. The `pipeline` block records the classifier, the feature version, the full config and `isDefaultConfig`.
- `--config` takes a JSON file with the keys `repCounter` and `heuristic`, each holding any of that config's thresholds (see `RepCounter.Config` and `HeuristicPoseClassifier.Config`). A missing key keeps its default, so `{"repCounter": {"minPhaseDuration": 0.7}}` overrides one threshold.

## Definitions

A take is one session entry in `predictions.json`. `p` is its `predictedReps` and `y` its `trueReps`.

### Valid sets

Takes with `kind == "set"` and `tags.cheat == "none"`.

| Metric | Formula |
|---|---|
| Exact-count accuracy | mean of `p == y` |
| Off-by-one accuracy | mean of `abs(p - y) <= 1` |
| MAE in reps | mean of `abs(p - y)` |
| Normalised MAE | mean of `abs(p - y) / (y + alpha)`, with `alpha = 0.1` |
| Signed bias | mean of `p - y` (negative means undercounting) |
| Totals | sum of `y` and sum of `p` |

`alpha` is the RepCount convention. It keeps the normalised error defined when `y = 0`. It is a named parameter (`ALPHA` in `metrics.py`) and every table that shows the normalised MAE prints its value.

### Cheat sets

Takes with `kind == "set"` and `tags.cheat != "none"`. `awarded = max(0, p - y)`. Reported per cheat type and overall:

- number of takes
- spoof acceptance rate: fraction of takes with `awarded >= 1`
- mean awarded reps per take
- missed valid reps: `max(0, y - p)`, summed over mixed sets (cheat sets with `y > 0`)

### Negatives

Takes with `kind == "negative"`.

- False reps per minute: `sum(p) / (sum(durationSeconds) / 60)`
- Fraction of clips with `p >= 1`

### Replay fidelity

Over takes that have a `live` block whose classifier equals the replay classifier: the fraction where `p == live.reps`. It checks that the replay matches what the app counted while recording, so it is only meaningful when the replay used the default config. The report prints it with that caveat and omits it when a non-default config was used.

### Per-condition breakdown

The valid-set metrics grouped by each of `lighting`, `distance`, `clothing`, `tempo`, `variant`, and by `subject`, with the number of takes and reps in each group. No intervals: the groups are too small.

## Sittings

Takes recorded in one sitting are correlated (same place, light, clothes and tiredness), so the sitting, not the take, is the unit that is resampled for confidence intervals and the unit that is assigned to a split.

A sitting is a maximal run of takes by the same `subject`, sorted by `createdAt`, in which consecutive takes are less than 60 minutes apart. A gap of 60 minutes or more starts a new sitting. Sitting ids look like `S01-001`, numbered per subject in time order.

## Confidence intervals

Percentile cluster bootstrap over sittings: 10000 resamples, fixed seed 12345, 95 percent. Each resample draws sittings with replacement, pools their takes and recomputes the metric; the interval is the 2.5th and 97.5th percentiles of the resampled values. Every metric is a ratio of sums over takes, so pooling and recomputing is done by summing per-sitting numerators and denominators. The resampled sittings are those that hold at least one take of the kind the metric covers. With fewer than 2 sittings the point estimate is reported, the interval is `null` and a note says it cannot be estimated.

## Splits

`--splits` takes a JSON file that maps a sitting id or a take id to `"dev"` or `"test"`. When given, every table and figure is produced separately for dev and test (figures get a `_dev` or `_test` suffix). The assignment follows the train and test split in `docs/recording-protocol.md`, and `make_splits` writes it:

- for subject `S01`, the last three sittings in time order are `test` and the rest `dev`; with three or fewer sittings all are `dev` and a warning says the test set is empty
- every sitting of any other subject is `test`
- sittings of the synthetic subject `SYN` are `dev`

Nothing is tuned on the test split. If it is used for a decision, say so alongside the results.

## Outputs

Written to the output directory:

- `results.json`: all metrics, intervals, per-condition tables, the `pipeline` block from `predictions.json`, take counts by kind, and `synthetic`.
- `report.md`: headline table, cheat table, negatives, fidelity, per-condition tables and the ten worst valid sets.
- `count_error_hist.png`, `pred_vs_true.png`, `per_condition.png`.

`synthetic` is true when every take has subject `SYN`. The report then starts with a bold warning that the numbers exercise the harness and say nothing about real accuracy, and the figure titles carry the same warning.

## Synthetic sessions

`pushup-eval synth` writes twelve sessions in two sittings: clean sets with 3 to 15 reps at slow, normal and fast tempo, half reps, an arm wave, a mixed set and negative clips. They are built from the same geometric pose generator the unit tests use (`PushupSynth`), carry subject `SYN` and the note `synthetic`, and are deterministic for a given `--seed` (default 1). They contain no real human motion, so the counts they produce are a check that the tooling works, not a measure of the counter.
