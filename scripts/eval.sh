#!/usr/bin/env bash
# Replay recorded sessions through the shipped pipeline and write the report.
#
#   scripts/eval.sh [data-dir] [out-dir]
#
# Defaults: data/sessions and results (both relative to the repo root).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DATA="${1:-$ROOT/data/sessions}"
OUT="${2:-$ROOT/results}"

if [ ! -d "$DATA" ] || [ -z "$(find "$DATA" -maxdepth 1 -name '*.json' -print -quit)" ]; then
    echo "error: no session files (*.json) found in $DATA" >&2
    echo "Record takes with the app and copy them there, see docs/recording-protocol.md." >&2
    exit 1
fi

PACKAGE="$ROOT/Packages/PushupCore"
swift build -c release --package-path "$PACKAGE" --product pushup-eval
BIN="$(swift build -c release --package-path "$PACKAGE" --show-bin-path)/pushup-eval"

mkdir -p "$OUT"
"$BIN" replay --data "$DATA" --out "$OUT/predictions.json"
uv run --project "$ROOT/eval" python -m pushup_report.make_splits \
    --predictions "$OUT/predictions.json" --out "$OUT/splits.json"
uv run --project "$ROOT/eval" python -m pushup_report.report \
    --predictions "$OUT/predictions.json" --splits "$OUT/splits.json" --out "$OUT"
echo "report: $OUT/report.md"
