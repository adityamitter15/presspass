"""Write a dev/test split file for a predictions.json.

    python -m pushup_report.make_splits --predictions <json> --out <splits.json>

Implements the protocol in docs/recording-protocol.md, by sitting:

- for subject S01, the last three sittings in time order are ``test`` and the
  rest ``dev`` (with three or fewer sittings, all are ``dev`` and a warning
  says the test set is empty)
- every sitting of any other subject is ``test``
- sittings of the synthetic subject SYN are ``dev``
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from .sittings import assign_sittings, assign_splits


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="python -m pushup_report.make_splits", description=__doc__.split("\n\n")[0])
    parser.add_argument("--predictions", required=True, help="predictions.json written by pushup-eval replay")
    parser.add_argument("--out", required=True, help="splits.json to write")
    args = parser.parse_args(argv)

    takes = json.loads(Path(args.predictions).read_text())["sessions"]
    sittings = assign_sittings(takes)
    splits, warnings = assign_splits(takes, sittings)
    for message in warnings:
        print(f"warning: {message}", file=sys.stderr)

    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(splits, indent=2, sort_keys=True) + "\n")
    counts = {name: sum(1 for s in splits.values() if s == name) for name in ("dev", "test")}
    print(f"wrote {len(splits)} sittings ({counts['dev']} dev, {counts['test']} test) to {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
