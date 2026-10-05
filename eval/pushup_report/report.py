"""Turn a predictions.json from ``pushup-eval replay`` into metrics, tables and figures.

    python -m pushup_report.report --predictions <json> --out <dir> [--splits <json>] [--title <str>]

Writes ``results.json``, ``report.md`` and three figures into ``--out``. With
``--splits`` every table and figure is produced separately for ``dev`` and
``test``; the figures then carry a ``_dev`` or ``_test`` suffix.
"""

from __future__ import annotations

import argparse
import json
import sys
import textwrap
from collections import Counter
from pathlib import Path
from typing import Mapping, Sequence

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
import numpy as np  # noqa: E402

from . import metrics  # noqa: E402
from .sittings import (  # noqa: E402
    BOOTSTRAP_RESAMPLES,
    BOOTSTRAP_SEED,
    SYNTHETIC_SUBJECT,
    assign_sittings,
    format_interval,
    split_of,
)

RESULTS_SCHEMA = 1
SYNTHETIC_WARNING = "Synthetic data: these numbers exercise the harness and say nothing about real accuracy."
SPLIT_NAMES = ("dev", "test")
FIGURES = ("count_error_hist", "pred_vs_true", "per_condition")

LIGHTING_ORDER = ("daylight", "indoor_bright", "dim")
DISTANCE_ORDER = ("near", "mid", "far")


# ------------------------------------------------------------------ results

def is_synthetic(takes: Sequence[Mapping]) -> bool:
    """True when there is at least one take and every take has ``subject == "SYN"``."""
    return bool(takes) and all(t.get("subject") == SYNTHETIC_SUBJECT for t in takes)


def count_kinds(takes: Sequence[Mapping]) -> dict:
    counts = Counter(t.get("kind") for t in takes)
    return {"set": counts["set"], "negative": counts["negative"], "pose": counts["pose"], "total": len(takes)}


def build_section(takes: Sequence[Mapping], sittings: Mapping[str, str], pipeline: Mapping, alpha: float) -> dict:
    """All tables for one set of takes (everything, or one split)."""
    replay_classifier = pipeline.get("classifier")
    is_default = pipeline.get("isDefaultConfig")
    if pipeline.get("mode") == "session":
        fidelity = {"reported": False, "note": "omitted: a session-mode replay is not the counting path the older recordings were made with"}
    elif is_default is True:
        fidelity = {"reported": True, **metrics.replay_fidelity(takes, replay_classifier)}
    else:
        reason = "non-default config used for the replay" if is_default is False else "default config not confirmed"
        fidelity = {"reported": False, "note": f"omitted: {reason}"}

    return {
        "n_takes": count_kinds(takes),
        "n_sittings": len({sittings[t["id"]] for t in takes}),
        "valid_sets": {
            "metrics": metrics.valid_set_metrics(takes, alpha),
            "intervals": metrics.valid_set_intervals(takes, sittings, alpha),
        },
        "cheat_sets": {
            **metrics.cheat_metrics(takes),
            "intervals": metrics.cheat_intervals(takes, sittings),
        },
        "negatives": {
            "metrics": metrics.negative_metrics(takes),
            "intervals": metrics.negative_intervals(takes, sittings),
        },
        "fidelity": fidelity,
        "gates": metrics.gate_tables(takes),
        "conditions": metrics.condition_tables(takes, alpha),
        "worst_takes": metrics.worst_takes(takes),
    }


def split_takes(
    takes: Sequence[Mapping], sittings: Mapping[str, str], splits: Mapping[str, str]
) -> tuple[dict[str, list[Mapping]], int]:
    """Takes per split name, and the number of takes the split file does not cover."""
    out: dict[str, list[Mapping]] = {name: [] for name in SPLIT_NAMES}
    unassigned = 0
    for take in takes:
        name = split_of(take, sittings, splits)
        if name in out:
            out[name].append(take)
        else:
            unassigned += 1
    return out, unassigned


def build_results(
    predictions: Mapping,
    splits: Mapping[str, str] | None = None,
    title: str = "Pushup counter evaluation",
    alpha: float = metrics.ALPHA,
) -> tuple[dict, dict[str, list[Mapping]]]:
    """Compute ``results.json`` content and the takes behind each section."""
    all_takes = predictions["sessions"]
    # Workout logs from the app have no human count: they take no part in any metric.
    takes = metrics.evaluation_takes(all_takes)
    ignored = len(all_takes) - len(takes)
    sittings = assign_sittings(takes)
    pipeline = predictions.get("pipeline", {})

    if splits is None:
        groups = {"all": list(takes)}
        unassigned = 0
    else:
        groups, unassigned = split_takes(takes, sittings, splits)

    results = {
        "schema": RESULTS_SCHEMA,
        "title": title,
        "synthetic": is_synthetic(takes),
        "alpha": alpha,
        "pipeline": pipeline,
        "n_takes": count_kinds(takes),
        "skipped_files": predictions.get("skipped", []),
        "ignored_workout_takes": ignored,
        "splits_given": splits is not None,
        "unassigned_takes": unassigned,
        "bootstrap": {
            "unit": "sitting",
            "resamples": BOOTSTRAP_RESAMPLES,
            "seed": BOOTSTRAP_SEED,
            "level": 0.95,
        },
        "sections": {name: build_section(group, sittings, pipeline, alpha) for name, group in groups.items()},
    }
    return results, groups


# ----------------------------------------------------------------- markdown

def fmt(value: float | None, digits: int = 3) -> str:
    return "n/a" if value is None else f"{value:.{digits}f}"


def section_title(name: str) -> str:
    return {"all": "All takes", "dev": "Dev split", "test": "Test split"}.get(name, name)


def figure_name(base: str, section: str) -> str:
    return f"{base}.png" if section == "all" else f"{base}_{section}.png"


def render_markdown(results: Mapping) -> str:
    alpha = results["alpha"]
    lines: list[str] = []
    if results["synthetic"]:
        lines += [f"**{SYNTHETIC_WARNING}**", ""]
    lines += [f"# {results['title']}", ""]

    pipe = results["pipeline"]
    kinds = results["n_takes"]
    lines += [
        f"- Classifier: {pipe.get('classifier', 'unknown')}, feature version {pipe.get('featureVersion', 'unknown')}"
        + (f", model {pipe['model']}" if pipe.get("model") else ""),
        "- Replay mode: " + ("session (the workout session engine)" if pipe.get("mode") == "session" else "raw (counting pipeline only)"),
        "- Config: " + (
            "default" if pipe.get("isDefaultConfig") is True
            else "NON-DEFAULT, see results.json" if pipe.get("isDefaultConfig") is False
            else "not confirmed as default"
        ),
        f"- Takes: {kinds['total']} ({kinds['set']} sets, {kinds['negative']} negative clips, {kinds['pose']} held poses)",
        f"- Skipped files: {len(results['skipped_files'])}",
        f"- Workout logs ignored: {results.get('ignored_workout_takes', 0)}",
        f"- Intervals: 95 percent percentile cluster bootstrap over sittings, {results['bootstrap']['resamples']} "
        f"resamples, seed {results['bootstrap']['seed']}",
    ]
    if results["splits_given"]:
        lines.append(f"- Takes not covered by the split file: {results['unassigned_takes']}")
    lines.append("")

    for name, section in results["sections"].items():
        lines += render_section(name, section, alpha, results["synthetic"])
    return "\n".join(lines).rstrip() + "\n"


def render_section(name: str, section: Mapping, alpha: float, synthetic: bool) -> list[str]:
    kinds = section["n_takes"]
    lines = [f"## {section_title(name)}", ""]
    lines += [f"{kinds['total']} takes in {section['n_sittings']} sittings.", ""]
    if kinds["total"] == 0:
        return lines + ["No takes in this section.", ""]

    # Headline table.
    valid = section["valid_sets"]["metrics"]
    intervals = section["valid_sets"]["intervals"]
    lines += ["### Valid sets", ""]
    if valid["n_takes"] == 0:
        lines += ["No valid sets.", ""]
    else:
        rows = [
            ("Exact-count accuracy", "exact_count_accuracy"),
            ("Off-by-one accuracy", "off_by_one_accuracy"),
            ("MAE (reps)", "mae"),
            (f"Normalised MAE (alpha = {alpha:g})", "normalised_mae"),
            ("Signed bias (reps, negative = undercount)", "signed_bias"),
        ]
        lines += ["| Metric | Value | 95% interval |", "|---|---|---|"]
        for label, key in rows:
            lines.append(f"| {label} | {fmt(valid[key])} | {format_interval(intervals[key])} |")
        lines += [
            "",
            f"{valid['n_takes']} valid sets, {valid['total_true_reps']} true reps, "
            f"{valid['total_predicted_reps']} predicted reps.",
        ]
        notes = sorted({ci["note"] for ci in intervals.values() if ci.get("note")})
        lines += [f"Interval note: {n}." for n in notes]
        lines.append("")

    # Cheat table.
    cheat = section["cheat_sets"]
    lines += ["### Cheat sets", ""]
    if cheat["overall"]["n_takes"] == 0:
        lines += ["No cheat sets.", ""]
    else:
        lines += [
            "| Cheat | Takes | Spoof acceptance | Mean awarded reps | Mixed takes | Missed valid reps |",
            "|---|---|---|---|---|---|",
        ]
        for kind, row in cheat["by_type"].items():
            lines.append(cheat_row(kind, row))
        lines.append(cheat_row("overall", cheat["overall"]))
        ci = cheat["intervals"]
        lines += [
            "",
            f"Overall spoof acceptance interval {format_interval(ci['spoof_acceptance_rate'])}, "
            f"mean awarded reps interval {format_interval(ci['mean_awarded_reps'])}.",
            "Spoof acceptance is the fraction of takes where the counter awarded at least one rep beyond the true count.",
            "",
        ]

    # Negatives.
    neg = section["negatives"]["metrics"]
    neg_ci = section["negatives"]["intervals"]
    lines += ["### Negative clips", ""]
    if neg["n_clips"] == 0:
        lines += ["No negative clips.", ""]
    else:
        lines += [
            f"{neg['n_clips']} clips, {fmt(neg['total_minutes'], 2)} minutes: "
            f"{neg['false_reps']} false reps, {fmt(neg['false_reps_per_minute'])} per minute "
            f"(interval {format_interval(neg_ci['false_reps_per_minute'])}); "
            f"{fmt(neg['fraction_with_false_rep'])} of clips had at least one false rep "
            f"(interval {format_interval(neg_ci['fraction_with_false_rep'])}).",
            "",
        ]

    # Fidelity.
    fid = section["fidelity"]
    lines += ["### Replay fidelity", ""]
    if not fid["reported"]:
        lines += [f"Not reported ({fid['note']}).", ""]
    elif fid["n_eligible"] == 0:
        lines += ["No take has a live result from the same classifier.", ""]
    else:
        lines += [
            f"The replay matched the app's live count on {fid['n_match']} of {fid['n_eligible']} takes "
            f"({fmt(fid['fidelity'])}). Only meaningful because the replay used the default config.",
            "",
        ]

    # Gates (session-mode replays only).
    gates = section.get("gates")
    if gates:
        lines += [
            "### Frames rejected by each gate",
            "",
            "First failing check per frame, in the order the engine checks them. Frames in takes that never started are included.",
            "",
            "| Group | Takes | Started | Frames | No body | Low confidence | Not in posture | Not horizontal | Hands moving | Passed |",
            "|---|---|---|---|---|---|---|---|---|---|",
        ]
        for label, key in (("Valid sets", "valid_sets"), ("Cheat sets", "cheat_sets"), ("Negative clips", "negatives")):
            row = gates[key]
            cells = " | ".join(gate_cell(row, k) for k in metrics.GATE_KEYS)
            lines.append(f"| {label} | {row['n_takes']} | {row['n_started']} | {row['frames']} | {cells} |")
        lines.append("")

    # Conditions.
    lines += ["### Valid sets by condition", ""]
    for key, groups in section["conditions"].items():
        if not groups:
            continue
        lines += [
            f"**{key}**",
            "",
            f"| {key} | Takes | True reps | Exact | Off-by-one | MAE | Norm. MAE (alpha = {alpha:g}) | Bias |",
            "|---|---|---|---|---|---|---|---|",
        ]
        for value, row in groups.items():
            lines.append(
                f"| {value} | {row['n_takes']} | {row['n_reps']} | {fmt(row['exact_count_accuracy'])} | "
                f"{fmt(row['off_by_one_accuracy'])} | {fmt(row['mae'])} | {fmt(row['normalised_mae'])} | "
                f"{fmt(row['signed_bias'])} |"
            )
        lines.append("")

    # Worst takes.
    lines += ["### Worst takes", ""]
    worst = section["worst_takes"]
    if not worst:
        lines += ["No valid set was miscounted.", ""]
    else:
        lines += ["| File | True | Predicted | Tags |", "|---|---|---|---|"]
        for item in worst:
            tags = ", ".join(f"{k}={v}" for k, v in item["tags"].items())
            lines.append(f"| {item['file']} | {item['true']} | {item['predicted']} | {tags} |")
        lines.append("")

    # Figures.
    lines += ["### Figures", ""]
    for base in FIGURES:
        lines.append(f"![{base}]({figure_name(base, name)})")
    lines.append("")
    return lines


def gate_cell(row: Mapping, key: str) -> str:
    """A frame count with its share of the group's frames."""
    frames = row["frames"]
    share = f" ({100 * row[key] / frames:.1f}%)" if frames else ""
    return f"{row[key]}{share}"


def cheat_row(kind: str, row: Mapping) -> str:
    missed = str(row["missed_valid_reps"]) if row["n_mixed_takes"] else "n/a"
    return (
        f"| {kind} | {row['n_takes']} | {fmt(row['spoof_acceptance_rate'])} | "
        f"{fmt(row['mean_awarded_reps'])} | {row['n_mixed_takes']} | {missed} |"
    )


# ------------------------------------------------------------------ figures

def _title(text: str, synthetic: bool) -> str:
    if not synthetic:
        return text
    return "\n".join(textwrap.wrap(SYNTHETIC_WARNING, 70) + [text])


def _empty(ax, message: str = "no valid sets") -> None:
    ax.text(0.5, 0.5, message, ha="center", va="center", transform=ax.transAxes)
    ax.set_xticks([])
    ax.set_yticks([])


def plot_count_error_hist(takes: Sequence[Mapping], path: Path, synthetic: bool) -> None:
    """Histogram of the signed error ``p - y`` on valid sets, one bin per integer."""
    sets = metrics.valid_sets(takes)
    fig, ax = plt.subplots(figsize=(6.5, 4.5))
    if sets:
        errors = np.array([t["predictedReps"] - t["trueReps"] for t in sets])
        edges = np.arange(errors.min() - 0.5, errors.max() + 1.5, 1.0)
        ax.hist(errors, bins=edges, color="C0", edgecolor="white")
        ax.set_xticks(np.arange(errors.min(), errors.max() + 1))
        ax.set_xlabel("Signed error, predicted minus true reps (negative = undercount)")
        ax.set_ylabel("Valid sets")
    else:
        _empty(ax)
    ax.set_title(_title(f"Count error on valid sets (n = {len(sets)})", synthetic), fontsize=9)
    fig.tight_layout()
    fig.savefig(path, dpi=150)
    plt.close(fig)


def plot_pred_vs_true(takes: Sequence[Mapping], path: Path, synthetic: bool) -> None:
    """Predicted against true reps on valid sets; point area grows with how many sets share the point."""
    sets = metrics.valid_sets(takes)
    fig, ax = plt.subplots(figsize=(5.5, 5.5))
    if sets:
        counts = Counter((t["trueReps"], t["predictedReps"]) for t in sets)
        xs = [k[0] for k in counts]
        ys = [k[1] for k in counts]
        sizes = [40 * n for n in counts.values()]
        top = max(max(xs), max(ys)) + 1
        ax.plot([0, top], [0, top], color="0.5", linestyle="--", linewidth=1, label="identity")
        ax.scatter(xs, ys, s=sizes, color="C0", alpha=0.7, label="valid sets (area = frequency)")
        ax.set_xlim(-0.5, top)
        ax.set_ylim(-0.5, top)
        ax.set_aspect("equal")
        ax.set_xlabel("True reps")
        ax.set_ylabel("Predicted reps")
        ax.legend(loc="upper left", fontsize=8)
    else:
        _empty(ax)
    ax.set_title(_title(f"Predicted against true reps (n = {len(sets)})", synthetic), fontsize=9)
    fig.tight_layout()
    fig.savefig(path, dpi=150)
    plt.close(fig)


def _ordered(groups: Mapping[str, Mapping], order: Sequence[str]) -> list[str]:
    return [v for v in order if v in groups] + sorted(v for v in groups if v not in order)


def plot_per_condition(takes: Sequence[Mapping], path: Path, synthetic: bool) -> None:
    """Exact-count accuracy by lighting and by distance, take counts above the bars."""
    sets = metrics.valid_sets(takes)
    panels = [
        ("lighting", metrics.group_metrics(sets, "lighting"), LIGHTING_ORDER),
        ("distance", metrics.group_metrics(sets, "distance"), DISTANCE_ORDER),
    ]
    fig, axes = plt.subplots(1, 2, figsize=(9, 4.5), sharey=True)
    for ax, (key, groups, order) in zip(axes, panels):
        if not groups:
            _empty(ax)
            ax.set_title(key)
            continue
        names = _ordered(groups, order)
        values = [groups[n]["exact_count_accuracy"] for n in names]
        bars = ax.bar(range(len(names)), values, color="C0")
        for bar, name in zip(bars, names):
            ax.annotate(
                f"n = {groups[name]['n_takes']}",
                (bar.get_x() + bar.get_width() / 2, bar.get_height()),
                ha="center", va="bottom", fontsize=8, xytext=(0, 2), textcoords="offset points",
            )
        ax.set_xticks(range(len(names)))
        ax.set_xticklabels(names)
        ax.set_xlabel(key)
        ax.set_ylim(0, 1.1)
    axes[0].set_ylabel("Exact-count accuracy")
    fig.suptitle(_title(f"Exact-count accuracy by condition (valid sets, n = {len(sets)})", synthetic), fontsize=9)
    fig.tight_layout()
    fig.savefig(path, dpi=150)
    plt.close(fig)


def write_figures(groups: Mapping[str, Sequence[Mapping]], out: Path, synthetic: bool) -> list[str]:
    written = []
    for name, takes in groups.items():
        for base, draw in (
            ("count_error_hist", plot_count_error_hist),
            ("pred_vs_true", plot_pred_vs_true),
            ("per_condition", plot_per_condition),
        ):
            file = figure_name(base, name)
            draw(takes, out / file, synthetic)
            written.append(file)
    return written


# --------------------------------------------------------------------- main

def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="python -m pushup_report.report",
        description="Metrics, tables and figures from a pushup-eval predictions file.",
    )
    parser.add_argument("--predictions", required=True, help="predictions.json written by pushup-eval replay")
    parser.add_argument("--out", required=True, help="directory for results.json, report.md and the figures")
    parser.add_argument("--splits", help="JSON mapping sitting id or take id to dev or test")
    parser.add_argument("--title", default="Pushup counter evaluation", help="report title")
    args = parser.parse_args(argv)

    predictions = json.loads(Path(args.predictions).read_text())
    splits = json.loads(Path(args.splits).read_text()) if args.splits else None

    results, groups = build_results(predictions, splits, args.title)
    if results["unassigned_takes"]:
        print(f"warning: {results['unassigned_takes']} takes are not covered by the split file", file=sys.stderr)

    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    (out / "results.json").write_text(json.dumps(results, indent=2, sort_keys=True) + "\n")
    (out / "report.md").write_text(render_markdown(results))
    write_figures(groups, out, results["synthetic"])
    print(f"wrote {out / 'report.md'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
