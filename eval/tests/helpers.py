"""Builders for hand-made predictions with known answers."""

from __future__ import annotations

DEFAULT_PIPELINE = {
    "classifier": "heuristic",
    "featureVersion": "v1",
    "isDefaultConfig": True,
    "config": {},
}


def make_take(
    name: str,
    true,
    pred: int,
    *,
    kind: str = "set",
    cheat: str = "none",
    subject: str = "S01",
    created: str = "2026-07-04T09:00:00Z",
    duration: float = 20.0,
    live: dict | None = None,
    lighting: str = "indoor_bright",
    distance: str = "mid",
    clothing: str = "fitted",
    tempo: str = "normal",
    variant: str = "standard",
    gate_counts: dict | None = None,
    started: bool | None = None,
) -> dict:
    take = {
        "id": name,
        "file": f"{name}.json",
        "kind": kind,
        "subject": subject,
        "createdAt": created,
        "tags": {
            "lighting": lighting,
            "distance": distance,
            "clothing": clothing,
            "tempo": tempo,
            "variant": variant,
            "cheat": cheat,
        },
        "notes": "",
        "predictedReps": pred,
        "rejectedReps": 0,
        "repTimes": [],
        "frames": 600,
        "durationSeconds": duration,
        "meanFps": 30.0,
    }
    if true is not None:
        take["trueReps"] = true
    if live is not None:
        take["live"] = live
    if gate_counts is not None:
        take["gateCounts"] = gate_counts
    if started is not None:
        take["started"] = started
    return take


def make_predictions(takes: list[dict], pipeline: dict | None = None, skipped: list | None = None) -> dict:
    return {
        "schema": 1,
        "tool": "pushup-eval",
        "pipeline": dict(pipeline or DEFAULT_PIPELINE),
        "sessions": takes,
        "skipped": skipped or [],
    }
