import json

import pytest

from helpers import make_predictions, make_take
from pushup_report import report

WARNING = "**Synthetic data: these numbers exercise the harness and say nothing about real accuracy.**"


def synthetic_predictions():
    takes = [
        make_take("s1", 5, 5, subject="SYN", created="2026-01-10T10:00:00Z", live={"reps": 5, "rejectedReps": 0, "classifier": "heuristic"}),
        make_take("s2", 8, 7, subject="SYN", created="2026-01-10T10:05:00Z", live={"reps": 7, "rejectedReps": 0, "classifier": "heuristic"}),
        make_take("s3", 4, 4, subject="SYN", created="2026-01-10T15:00:00Z", lighting="dim", distance="far"),
        make_take("c1", 0, 1, subject="SYN", created="2026-01-10T15:05:00Z", cheat="half_reps"),
        make_take("n1", 0, 0, subject="SYN", created="2026-01-10T15:10:00Z", kind="negative", duration=30),
    ]
    return make_predictions(takes)


def real_predictions():
    takes = [
        make_take("r1", 5, 5, subject="S01", created="2026-07-04T09:00:00Z"),
        make_take("r2", 6, 6, subject="S02", created="2026-07-05T09:00:00Z"),
    ]
    return make_predictions(takes)


def run_report(tmp_path, predictions, splits=None, *extra):
    source = tmp_path / "predictions.json"
    source.write_text(json.dumps(predictions))
    args = ["--predictions", str(source), "--out", str(tmp_path / "out")]
    if splits is not None:
        splits_file = tmp_path / "splits.json"
        splits_file.write_text(json.dumps(splits))
        args += ["--splits", str(splits_file)]
    assert report.main([*args, *extra]) == 0
    return tmp_path / "out"


def test_report_writes_all_five_files(tmp_path):
    out = run_report(tmp_path, synthetic_predictions())
    for name in ("results.json", "report.md", "count_error_hist.png", "pred_vs_true.png", "per_condition.png"):
        path = out / name
        assert path.is_file() and path.stat().st_size > 0, name
    assert (out / "count_error_hist.png").read_bytes()[:8] == b"\x89PNG\r\n\x1a\n"


def test_synthetic_flag_and_warning(tmp_path):
    out = run_report(tmp_path, synthetic_predictions())
    results = json.loads((out / "results.json").read_text())
    assert results["synthetic"] is True
    first_line = (out / "report.md").read_text().splitlines()[0]
    assert first_line == WARNING


def test_real_data_is_not_flagged_synthetic(tmp_path):
    out = run_report(tmp_path, real_predictions())
    results = json.loads((out / "results.json").read_text())
    assert results["synthetic"] is False
    assert "Synthetic data" not in (out / "report.md").read_text()


def test_one_non_synthetic_take_clears_the_flag():
    predictions = synthetic_predictions()
    predictions["sessions"].append(make_take("real", 5, 5, subject="S01"))
    results, _ = report.build_results(predictions)
    assert results["synthetic"] is False


def test_results_content():
    predictions = synthetic_predictions()
    results, _ = report.build_results(predictions)
    assert results["pipeline"] == predictions["pipeline"]
    assert results["n_takes"] == {"set": 4, "negative": 1, "pose": 0, "total": 5}
    assert results["alpha"] == 0.1
    section = results["sections"]["all"]
    valid = section["valid_sets"]["metrics"]
    assert valid["n_takes"] == 3
    assert valid["exact_count_accuracy"] == pytest.approx(2 / 3)
    assert section["valid_sets"]["intervals"]["exact_count_accuracy"]["n_sittings"] == 2
    assert section["cheat_sets"]["overall"]["spoof_acceptance_rate"] == 1.0
    assert section["negatives"]["metrics"]["false_reps_per_minute"] == 0.0
    assert section["fidelity"] == {"reported": True, "n_eligible": 2, "n_match": 2, "fidelity": 1.0}
    assert section["n_sittings"] == 2


def test_fidelity_is_omitted_for_a_non_default_config():
    predictions = synthetic_predictions()
    predictions["pipeline"]["isDefaultConfig"] = False
    results, _ = report.build_results(predictions)
    assert results["sections"]["all"]["fidelity"]["reported"] is False
    markdown = report.render_markdown(results)
    assert "Replay fidelity" in markdown
    assert "Not reported" in markdown
    assert "NON-DEFAULT" in markdown


def test_markdown_sections_and_alpha(tmp_path):
    text = (run_report(tmp_path, synthetic_predictions()) / "report.md").read_text()
    for heading in ("### Valid sets", "### Cheat sets", "### Negative clips", "### Replay fidelity",
                    "### Valid sets by condition", "### Worst takes"):
        assert heading in text
    assert "alpha = 0.1" in text
    assert "95% interval" in text
    assert "s2.json" in text  # the worst take
    assert chr(0x2014) not in text


def test_single_sitting_reports_no_interval(tmp_path):
    predictions = make_predictions([make_take("only", 5, 4)])
    results, _ = report.build_results(predictions)
    ci = results["sections"]["all"]["valid_sets"]["intervals"]["mae"]
    assert ci["lower"] is None and ci["upper"] is None
    assert "cannot be estimated" in ci["note"]
    assert "cannot be estimated" in report.render_markdown(results)


def test_splits_produce_separate_sections_and_figures(tmp_path):
    predictions = synthetic_predictions()
    out = run_report(tmp_path, predictions, {"SYN-001": "dev", "SYN-002": "test"})
    results = json.loads((out / "results.json").read_text())
    assert results["splits_given"] is True
    assert set(results["sections"]) == {"dev", "test"}
    assert results["sections"]["dev"]["valid_sets"]["metrics"]["n_takes"] == 2
    assert results["sections"]["test"]["valid_sets"]["metrics"]["n_takes"] == 1
    assert results["unassigned_takes"] == 0
    for split in ("dev", "test"):
        assert (out / f"per_condition_{split}.png").is_file()
    text = (out / "report.md").read_text()
    assert "## Dev split" in text and "## Test split" in text


def test_an_empty_split_still_renders(tmp_path):
    out = run_report(tmp_path, synthetic_predictions(), {"SYN-001": "dev", "SYN-002": "dev"})
    results = json.loads((out / "results.json").read_text())
    assert results["sections"]["test"]["n_takes"]["total"] == 0
    assert "No takes in this section." in (out / "report.md").read_text()
    assert (out / "count_error_hist_test.png").is_file()


def test_unassigned_takes_are_counted():
    results, groups = report.build_results(synthetic_predictions(), {"SYN-001": "dev"})
    assert results["unassigned_takes"] == 3
    assert len(groups["dev"]) == 2


def test_title_option(tmp_path):
    out = run_report(tmp_path, real_predictions(), None, "--title", "My run")
    assert (out / "report.md").read_text().startswith("# My run")


def test_no_miscounted_set_gives_a_line_and_an_empty_list(tmp_path):
    predictions = make_predictions([make_take("e1", 5, 5), make_take("e2", 7, 7, created="2026-07-05T09:00:00Z")])
    out = run_report(tmp_path, predictions)
    results = json.loads((out / "results.json").read_text())
    assert results["sections"]["all"]["worst_takes"] == []
    text = (out / "report.md").read_text()
    assert "No valid set was miscounted." in text
    assert "| File | True | Predicted | Tags |" not in text
