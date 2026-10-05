#!/usr/bin/env bash
# Replay recorded sessions through the shipped pipeline and write the report.
#
#   scripts/eval.sh [data-dir] [out-dir] [mode]
#
# mode is raw (the default) or session, from the third argument or the MODE
# environment variable. raw feeds a bare counting pipeline. session runs each
# take through the workout session engine the app uses (start hold, posture
# gates, finishing). Defaults: data/sessions, and results for raw or
# results-session for session, so the two runs can be compared side by side.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DATA="${1:-$ROOT/data/sessions}"
MODE="${3:-${MODE:-raw}}"
case "$MODE" in
    raw) DEFAULT_OUT="$ROOT/results" ;;
    session) DEFAULT_OUT="$ROOT/results-session" ;;
    *)
        echo "error: mode must be raw or session, got '$MODE'" >&2
        exit 2
        ;;
esac
OUT="${2:-$DEFAULT_OUT}"

if [ ! -d "$DATA" ] || [ -z "$(find "$DATA" -maxdepth 1 -name '*.json' -print -quit)" ]; then
    echo "error: no session files (*.json) found in $DATA" >&2
    echo "Record takes with the app and copy them there, see docs/recording-protocol.md." >&2
    exit 1
fi

PACKAGE="$ROOT/Packages/PushupCore"
swift build -c release --package-path "$PACKAGE" --product pushup-eval
BIN="$(swift build -c release --package-path "$PACKAGE" --show-bin-path)/pushup-eval"

mkdir -p "$OUT"
"$BIN" replay --data "$DATA" --out "$OUT/predictions.json" --mode "$MODE"
uv run --project "$ROOT/eval" python -m pushup_report.make_splits \
    --predictions "$OUT/predictions.json" --out "$OUT/splits.json"
uv run --project "$ROOT/eval" python -m pushup_report.report \
    --predictions "$OUT/predictions.json" --splits "$OUT/splits.json" --out "$OUT" \
    --title "Pushup counter evaluation ($MODE mode)"
echo "report: $OUT/report.md"
