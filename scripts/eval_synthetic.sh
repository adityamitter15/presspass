#!/usr/bin/env bash
# Smoke test for the evaluation tools: generate synthetic sessions into a
# temporary directory and run the whole pipeline on them. Never writes into
# data/sessions or results. The numbers it produces say nothing about real
# accuracy.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/pushup-eval-synthetic.XXXXXX")"
DATA="$WORK/sessions"
OUT="$WORK/results"

PACKAGE="$ROOT/Packages/PushupCore"
swift build -c release --package-path "$PACKAGE" --product pushup-eval
BIN="$(swift build -c release --package-path "$PACKAGE" --show-bin-path)/pushup-eval"

"$BIN" synth --out "$DATA"
mkdir -p "$OUT"
"$BIN" replay --data "$DATA" --out "$OUT/predictions.json"
uv run --project "$ROOT/eval" python -m pushup_report.make_splits \
    --predictions "$OUT/predictions.json" --out "$OUT/splits.json"
uv run --project "$ROOT/eval" python -m pushup_report.report \
    --predictions "$OUT/predictions.json" --splits "$OUT/splits.json" --out "$OUT" \
    --title "Synthetic smoke test"
echo "report: $OUT/report.md"
