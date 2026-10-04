"""Sittings, split assignment and the cluster bootstrap.

Takes recorded in one sitting share a subject, lighting, clothing and mood, so
they are correlated. The sitting is therefore the unit that is resampled when
a confidence interval is computed, and the unit that is assigned to a split.
"""

from __future__ import annotations

from collections import defaultdict
from datetime import datetime, timezone
from typing import Mapping, Sequence

import numpy as np

SITTING_GAP_MINUTES = 60
BOOTSTRAP_RESAMPLES = 10_000
BOOTSTRAP_SEED = 12345
CONFIDENCE_LEVEL = 0.95

#: The subject whose test sittings are the last three in time order.
PRIMARY_SUBJECT = "S01"
TEST_SITTINGS_FOR_PRIMARY = 3
SYNTHETIC_SUBJECT = "SYN"


def parse_time(text: str) -> datetime:
    """Parse an ISO 8601 timestamp such as ``2026-07-04T09:30:15Z`` to an aware UTC datetime."""
    parsed = datetime.fromisoformat(text.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed


def assign_sittings(takes: Sequence[Mapping], gap_minutes: float = SITTING_GAP_MINUTES) -> dict[str, str]:
    """Group takes into sittings and return ``{take id: sitting id}``.

    A sitting is a maximal run of takes by the same ``subject``, sorted by
    ``createdAt``, in which consecutive takes are strictly less than
    ``gap_minutes`` apart (a gap of exactly ``gap_minutes`` starts a new
    sitting). Sitting ids are ``<subject>-<NNN>``, numbered per subject in
    time order from 001. Ties in time are broken by file name.
    """
    by_subject: dict[str, list[tuple[datetime, str, str]]] = defaultdict(list)
    for take in takes:
        created = take.get("createdAt")
        if not created:
            raise ValueError(f"take {take.get('file', take.get('id'))!r} has no createdAt")
        by_subject[take.get("subject") or "UNKNOWN"].append(
            (parse_time(created), take.get("file", ""), take["id"])
        )

    assignment: dict[str, str] = {}
    for subject in sorted(by_subject):
        number = 0
        previous: datetime | None = None
        for when, _file, take_id in sorted(by_subject[subject]):
            if previous is None or (when - previous).total_seconds() / 60 >= gap_minutes:
                number += 1
            previous = when
            assignment[take_id] = f"{subject}-{number:03d}"
    return assignment


def group_by_sitting(takes: Sequence[Mapping], sittings: Mapping[str, str]) -> dict[str, list[Mapping]]:
    """Takes grouped by sitting id, with sittings in sorted id order."""
    groups: dict[str, list[Mapping]] = defaultdict(list)
    for take in takes:
        groups[sittings[take["id"]]].append(take)
    return dict(sorted(groups.items()))


def sitting_subjects(takes: Sequence[Mapping], sittings: Mapping[str, str]) -> dict[str, str]:
    """``{sitting id: subject}``."""
    return {sittings[t["id"]]: t.get("subject") or "UNKNOWN" for t in takes}


def assign_splits(takes: Sequence[Mapping], sittings: Mapping[str, str] | None = None) -> tuple[dict[str, str], list[str]]:
    """Assign every sitting to ``dev`` or ``test`` per docs/recording-protocol.md.

    - Sittings whose subject is ``SYN`` are ``dev``.
    - For subject ``S01`` the last three sittings in time order are ``test``
      and the rest ``dev``. If ``S01`` has three or fewer sittings they are
      all ``dev`` and a warning says the test set is empty.
    - Every sitting of any other subject is ``test``.

    Returns ``({sitting id: split}, [warnings])``.
    """
    sittings = dict(sittings) if sittings is not None else assign_sittings(takes)
    subjects = sitting_subjects(takes, sittings)
    messages: list[str] = []
    splits: dict[str, str] = {}

    primary = sorted(s for s, subject in subjects.items() if subject == PRIMARY_SUBJECT)
    for sitting, subject in subjects.items():
        if subject == SYNTHETIC_SUBJECT:
            splits[sitting] = "dev"
        elif subject != PRIMARY_SUBJECT:
            splits[sitting] = "test"

    if len(primary) <= TEST_SITTINGS_FOR_PRIMARY:
        for sitting in primary:
            splits[sitting] = "dev"
        if primary:
            messages.append(
                f"{PRIMARY_SUBJECT} has {len(primary)} sittings (need more than "
                f"{TEST_SITTINGS_FOR_PRIMARY}); all are dev, so the {PRIMARY_SUBJECT} test set is empty"
            )
    else:
        # Sitting ids are numbered in time order, so sorting the ids sorts the sittings.
        for sitting in primary[:-TEST_SITTINGS_FOR_PRIMARY]:
            splits[sitting] = "dev"
        for sitting in primary[-TEST_SITTINGS_FOR_PRIMARY:]:
            splits[sitting] = "test"
    return dict(sorted(splits.items())), messages


def split_of(take: Mapping, sittings: Mapping[str, str], splits: Mapping[str, str]) -> str | None:
    """The split of a take: its own id if listed, else its sitting id, else ``None``."""
    if take["id"] in splits:
        return splits[take["id"]]
    return splits.get(sittings[take["id"]])


def bootstrap_ratio_ci(
    per_sitting: Sequence[tuple[float, float]],
    *,
    scale: float = 1.0,
    n_resamples: int = BOOTSTRAP_RESAMPLES,
    seed: int = BOOTSTRAP_SEED,
    level: float = CONFIDENCE_LEVEL,
) -> dict:
    """Percentile cluster bootstrap of a ratio-of-sums metric over sittings.

    ``per_sitting`` holds one ``(numerator, denominator)`` pair per sitting.
    The metric is ``scale * sum(numerator) / sum(denominator)``. Every metric
    here is a mean over takes, so the pair is ``(sum of the per-take values,
    number of takes)``, or ``(false reps, minutes)`` for false reps per minute.
    Pooling the takes of a resample and recomputing the metric is the same
    thing as summing the pairs, which is what is done.

    Procedure: draw ``len(per_sitting)`` sittings with replacement,
    ``n_resamples`` times (10000), with ``numpy.random.default_rng(seed)``
    (seed 12345, so the same input always gives the same interval); recompute
    the metric for each; the interval is the 2.5th and 97.5th percentiles
    (for ``level`` 0.95) of the resampled values, ignoring resamples whose
    denominator is zero. With fewer than 2 sittings the interval cannot be
    estimated: ``lower`` and ``upper`` are ``None`` and ``note`` says so.
    """
    n_sittings = len(per_sitting)
    numerator = np.array([p[0] for p in per_sitting], dtype=float)
    denominator = np.array([p[1] for p in per_sitting], dtype=float)
    total_den = denominator.sum()
    estimate = float(scale * numerator.sum() / total_den) if total_den > 0 else None

    result = {
        "estimate": estimate,
        "lower": None,
        "upper": None,
        "n_sittings": n_sittings,
        "level": level,
        "n_resamples": n_resamples,
        "seed": seed,
        "note": None,
    }
    if estimate is None:
        result["note"] = "no takes, nothing to estimate"
        return result
    if n_sittings < 2:
        result["note"] = "fewer than 2 sittings, interval cannot be estimated"
        return result

    rng = np.random.default_rng(seed)
    picks = rng.integers(0, n_sittings, size=(n_resamples, n_sittings))
    num = numerator[picks].sum(axis=1)
    den = denominator[picks].sum(axis=1)
    valid = den > 0
    values = scale * num[valid] / den[valid]
    tail = (1 - level) / 2 * 100
    result["lower"] = float(np.percentile(values, tail))
    result["upper"] = float(np.percentile(values, 100 - tail))
    return result


def format_interval(ci: Mapping, digits: int = 3) -> str:
    """``[low, high]`` for a bootstrap result, or ``n/a`` when it has no interval."""
    if ci.get("lower") is None or ci.get("upper") is None:
        return "n/a"
    return f"[{ci['lower']:.{digits}f}, {ci['upper']:.{digits}f}]"
