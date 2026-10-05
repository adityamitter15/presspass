"""Metrics over pushup-eval replay output.

A "take" is one entry of ``sessions`` in predictions.json. ``p`` is the
take's ``predictedReps`` and ``y`` is its ``trueReps``.
"""

from __future__ import annotations

from collections import defaultdict
from typing import Callable, Mapping, Sequence

from .sittings import bootstrap_ratio_ci

#: Smoothing term of the normalised MAE (the RepCount convention).
ALPHA = 0.1

#: Tags the per-condition tables are grouped by, plus the subject.
CONDITION_KEYS = ("lighting", "distance", "clothing", "tempo", "variant")

Take = Mapping


def is_valid_set(take: Take) -> bool:
    """Valid set: ``kind == "set"``, ``tags.cheat == "none"`` and a known ``trueReps``."""
    return (
        take.get("kind") == "set"
        and take.get("tags", {}).get("cheat") == "none"
        and take.get("trueReps") is not None
    )


def is_cheat_set(take: Take) -> bool:
    """Cheat set: ``kind == "set"``, ``tags.cheat != "none"`` and a known ``trueReps``."""
    return (
        take.get("kind") == "set"
        and take.get("tags", {}).get("cheat") != "none"
        and take.get("trueReps") is not None
    )


def is_negative(take: Take) -> bool:
    """Negative clip: ``kind == "negative"``."""
    return take.get("kind") == "negative"


#: ``kind`` of a take the app wrote as an ordinary workout (the flight recorder). It has no
#: human count and is never part of the evaluation: no metric may see it.
IGNORED_KINDS = ("workout",)


def evaluation_takes(takes: Sequence[Take]) -> list[Take]:
    """The takes that belong to the evaluation: everything except ``kind == "workout"``."""
    return [t for t in takes if t.get("kind") not in IGNORED_KINDS]


def valid_sets(takes: Sequence[Take]) -> list[Take]:
    return [t for t in takes if is_valid_set(t)]


def cheat_sets(takes: Sequence[Take]) -> list[Take]:
    return [t for t in takes if is_cheat_set(t)]


def negatives(takes: Sequence[Take]) -> list[Take]:
    return [t for t in takes if is_negative(t)]


# ----------------------------------------------------------------- valid sets

def exact_value(take: Take, alpha: float = ALPHA) -> float:
    """1 if ``p == y`` else 0."""
    return float(take["predictedReps"] == take["trueReps"])


def off_by_one_value(take: Take, alpha: float = ALPHA) -> float:
    """1 if ``abs(p - y) <= 1`` else 0."""
    return float(abs(take["predictedReps"] - take["trueReps"]) <= 1)


def abs_error_value(take: Take, alpha: float = ALPHA) -> float:
    """``abs(p - y)``."""
    return float(abs(take["predictedReps"] - take["trueReps"]))


def normalised_error_value(take: Take, alpha: float = ALPHA) -> float:
    """``abs(p - y) / (y + alpha)``."""
    return abs(take["predictedReps"] - take["trueReps"]) / (take["trueReps"] + alpha)


def signed_error_value(take: Take, alpha: float = ALPHA) -> float:
    """``p - y`` (negative means undercounting)."""
    return float(take["predictedReps"] - take["trueReps"])


#: Per-take value of each valid-set metric; each metric is the mean over takes.
VALID_SET_VALUES: dict[str, Callable[[Take, float], float]] = {
    "exact_count_accuracy": exact_value,
    "off_by_one_accuracy": off_by_one_value,
    "mae": abs_error_value,
    "normalised_mae": normalised_error_value,
    "signed_bias": signed_error_value,
}


def _mean(values: Sequence[float]) -> float | None:
    return sum(values) / len(values) if values else None


def valid_set_metrics(takes: Sequence[Take], alpha: float = ALPHA) -> dict:
    """Metrics over the valid sets among ``takes``.

    - ``exact_count_accuracy``: mean of ``p == y``
    - ``off_by_one_accuracy``: mean of ``abs(p - y) <= 1``
    - ``mae``: mean of ``abs(p - y)``, in reps
    - ``normalised_mae``: mean of ``abs(p - y) / (y + alpha)``, ``alpha`` = 0.1
      unless given (so a set with ``y = 0`` is defined)
    - ``signed_bias``: mean of ``p - y`` (negative means undercounting)
    - ``total_true_reps`` = sum of ``y``, ``total_predicted_reps`` = sum of ``p``

    A metric over zero takes is ``None``.
    """
    sets = valid_sets(takes)
    result: dict = {"n_takes": len(sets), "alpha": alpha}
    for name, fn in VALID_SET_VALUES.items():
        result[name] = _mean([fn(t, alpha) for t in sets])
    result["total_true_reps"] = sum(t["trueReps"] for t in sets)
    result["total_predicted_reps"] = sum(t["predictedReps"] for t in sets)
    return result


def valid_set_intervals(takes: Sequence[Take], sittings: Mapping[str, str], alpha: float = ALPHA) -> dict:
    """95 percent cluster-bootstrap interval over sittings for each valid-set metric."""
    sets = valid_sets(takes)
    return {
        name: _mean_interval(sets, sittings, lambda t, fn=fn: fn(t, alpha))
        for name, fn in VALID_SET_VALUES.items()
    }


def _mean_interval(takes: Sequence[Take], sittings: Mapping[str, str], value: Callable[[Take], float]) -> dict:
    """Bootstrap a mean over takes: each sitting contributes (sum of values, take count)."""
    sums: dict[str, list[float]] = defaultdict(lambda: [0.0, 0.0])
    for take in takes:
        cell = sums[sittings[take["id"]]]
        cell[0] += value(take)
        cell[1] += 1
    return bootstrap_ratio_ci([(s, n) for _, (s, n) in sorted(sums.items())])


# ----------------------------------------------------------------- cheat sets

def awarded_reps(take: Take) -> int:
    """``max(0, p - y)``: reps awarded beyond the true count."""
    return max(0, take["predictedReps"] - take["trueReps"])


def missed_valid_reps(take: Take) -> int:
    """``max(0, y - p)``: valid reps in a take that the counter did not award."""
    return max(0, take["trueReps"] - take["predictedReps"])


def _cheat_group(group: Sequence[Take]) -> dict:
    mixed = [t for t in group if t["trueReps"] > 0]
    missed = sum(missed_valid_reps(t) for t in mixed)
    return {
        "n_takes": len(group),
        "spoof_acceptance_rate": _mean([float(awarded_reps(t) >= 1) for t in group]),
        "mean_awarded_reps": _mean([float(awarded_reps(t)) for t in group]),
        "n_mixed_takes": len(mixed),
        "missed_valid_reps": missed,
        "missed_valid_reps_per_mixed_take": missed / len(mixed) if mixed else None,
    }


def cheat_metrics(takes: Sequence[Take]) -> dict:
    """Metrics over cheat sets, overall and per ``tags.cheat`` value.

    For each take ``awarded = max(0, p - y)``. Reported per group:

    - ``n_takes``
    - ``spoof_acceptance_rate``: fraction of takes with ``awarded >= 1``
    - ``mean_awarded_reps``: mean of ``awarded``
    - ``missed_valid_reps``: sum of ``max(0, y - p)`` over takes with ``y > 0``
      (mixed sets, which hold some valid reps); ``n_mixed_takes`` counts them
    """
    sets = cheat_sets(takes)
    by_type: dict[str, list[Take]] = defaultdict(list)
    for take in sets:
        by_type[take["tags"]["cheat"]].append(take)
    return {
        "overall": _cheat_group(sets),
        "by_type": {kind: _cheat_group(group) for kind, group in sorted(by_type.items())},
    }


def cheat_intervals(takes: Sequence[Take], sittings: Mapping[str, str]) -> dict:
    """Cluster-bootstrap intervals for the overall cheat metrics."""
    sets = cheat_sets(takes)
    return {
        "spoof_acceptance_rate": _mean_interval(sets, sittings, lambda t: float(awarded_reps(t) >= 1)),
        "mean_awarded_reps": _mean_interval(sets, sittings, lambda t: float(awarded_reps(t))),
    }


# ------------------------------------------------------------------ negatives

def negative_metrics(takes: Sequence[Take]) -> dict:
    """Metrics over negative clips.

    - ``false_reps_per_minute`` = ``sum(p) / (sum(durationSeconds) / 60)``
    - ``fraction_with_false_rep``: fraction of clips with ``p >= 1``
    """
    clips = negatives(takes)
    minutes = sum(t["durationSeconds"] for t in clips) / 60
    false_reps = sum(t["predictedReps"] for t in clips)
    return {
        "n_clips": len(clips),
        "total_minutes": minutes,
        "false_reps": false_reps,
        "false_reps_per_minute": false_reps / minutes if minutes > 0 else None,
        "fraction_with_false_rep": _mean([float(t["predictedReps"] >= 1) for t in clips]),
    }


def negative_intervals(takes: Sequence[Take], sittings: Mapping[str, str]) -> dict:
    """Cluster-bootstrap intervals for the negative-clip metrics."""
    clips = negatives(takes)
    per_sitting: dict[str, list[float]] = defaultdict(lambda: [0.0, 0.0])
    for clip in clips:
        cell = per_sitting[sittings[clip["id"]]]
        cell[0] += clip["predictedReps"]
        cell[1] += clip["durationSeconds"] / 60
    return {
        "false_reps_per_minute": bootstrap_ratio_ci([(n, m) for _, (n, m) in sorted(per_sitting.items())]),
        "fraction_with_false_rep": _mean_interval(clips, sittings, lambda t: float(t["predictedReps"] >= 1)),
    }


# ------------------------------------------------------------------- fidelity

def replay_fidelity(takes: Sequence[Take], replay_classifier: str) -> dict:
    """Agreement between the replay and what the app counted live.

    Over takes that have a ``live`` block whose ``classifier`` equals the
    replay classifier: ``fidelity`` = fraction where ``p == live.reps``.
    ``None`` when no take is eligible. Only meaningful when the replay used
    the default config.
    """
    eligible = [
        t for t in takes
        if t.get("live") and t["live"].get("classifier") == replay_classifier
    ]
    matches = sum(1 for t in eligible if t["predictedReps"] == t["live"]["reps"])
    return {
        "n_eligible": len(eligible),
        "n_match": matches,
        "fidelity": matches / len(eligible) if eligible else None,
    }


# ------------------------------------------------------------ per-condition

def group_metrics(takes: Sequence[Take], key: str, alpha: float = ALPHA) -> dict:
    """Valid-set metrics grouped by a tag (``key`` in ``CONDITION_KEYS``) or by ``"subject"``.

    Each group reports the number of takes and true reps and the same metrics
    as ``valid_set_metrics``. No intervals: groups are too small.
    """
    groups: dict[str, list[Take]] = defaultdict(list)
    for take in valid_sets(takes):
        value = take.get("subject") if key == "subject" else take.get("tags", {}).get(key)
        groups[str(value)].append(take)
    out = {}
    for value, group in sorted(groups.items()):
        metrics = valid_set_metrics(group, alpha)
        metrics["n_reps"] = metrics["total_true_reps"]
        out[value] = metrics
    return out


def condition_tables(takes: Sequence[Take], alpha: float = ALPHA) -> dict:
    """``group_metrics`` for every condition key and for the subject."""
    return {key: group_metrics(takes, key, alpha) for key in (*CONDITION_KEYS, "subject")}


# ---------------------------------------------------------------- worst takes

def worst_takes(takes: Sequence[Take], n: int = 10) -> list[dict]:
    """The ``n`` valid sets with the largest ``abs(p - y)``, ties by file name.

    Only miscounted sets (``abs(p - y) >= 1``) are listed, so the result is
    empty when every valid set was counted exactly.
    """
    miscounted = [t for t in valid_sets(takes) if abs(t["predictedReps"] - t["trueReps"]) >= 1]
    ranked = sorted(miscounted, key=lambda t: (-abs(t["predictedReps"] - t["trueReps"]), t.get("file", "")))
    return [
        {
            "file": t.get("file"),
            "true": t["trueReps"],
            "predicted": t["predictedReps"],
            "tags": dict(t["tags"]),
        }
        for t in ranked[:n]
    ]


# ------------------------------------------------------------------ gates

#: Keys of ``gateCounts`` in a session-mode replay, in the engine's order of checking.
GATE_KEYS = ("noBody", "lowConfidence", "notInPosture", "notHorizontal", "handsMoving", "passed")


def gate_tables(takes: Sequence[Take]) -> dict | None:
    """Frames rejected by each session gate, summed over valid sets, cheat sets and negatives.

    Only takes that carry ``gateCounts`` (a session-mode replay) are used. Returns ``None`` when
    no take has it, so a raw-mode report has no such table. Per group: ``n_takes``, ``n_started``
    (takes with ``started`` true), ``frames`` and one frame count per key of ``GATE_KEYS``.
    """
    if not any("gateCounts" in t for t in takes):
        return None
    groups = {
        "valid_sets": valid_sets(takes),
        "cheat_sets": cheat_sets(takes),
        "negatives": negatives(takes),
    }
    out: dict = {}
    for name, group in groups.items():
        with_counts = [t for t in group if "gateCounts" in t]
        row: dict = {
            "n_takes": len(with_counts),
            "n_started": sum(1 for t in with_counts if t.get("started")),
        }
        for key in GATE_KEYS:
            row[key] = sum(t["gateCounts"].get(key, 0) for t in with_counts)
        row["frames"] = sum(row[key] for key in GATE_KEYS)
        out[name] = row
    return out
