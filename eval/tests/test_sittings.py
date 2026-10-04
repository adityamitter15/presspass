import json

import pytest

from helpers import make_predictions, make_take
from pushup_report import make_splits, sittings


def at(subject, name, time, day="2026-07-04"):
    return make_take(name, 5, 5, subject=subject, created=f"{day}T{time}:00Z")


def test_sitting_boundary_is_sixty_minutes():
    takes = [
        at("S01", "late", "11:30"),  # given out of order on purpose
        at("S01", "first", "09:00"),
        at("S01", "second", "09:59"),  # 59 minutes after the first: same sitting
        at("S01", "third", "10:59"),  # exactly 60 minutes after the second: new sitting
    ]
    result = sittings.assign_sittings(takes)
    assert result["first"] == result["second"] == "S01-001"
    assert result["third"] == result["late"] == "S01-002"


def test_sittings_are_chained_not_anchored_to_the_first_take():
    takes = [at("S01", "a", "09:00"), at("S01", "b", "09:50"), at("S01", "c", "10:40"), at("S01", "d", "11:30")]
    assert set(sittings.assign_sittings(takes).values()) == {"S01-001"}


def test_sittings_are_separate_per_subject_and_numbered_per_subject():
    takes = [
        at("S02", "s2a", "09:10"),
        at("S01", "s1a", "09:00"),
        at("S01", "s1b", "09:20"),
        at("S02", "s2b", "15:00"),
        at("S01", "s1c", "10:00", day="2026-07-05"),
    ]
    result = sittings.assign_sittings(takes)
    assert result["s1a"] == result["s1b"] == "S01-001"
    assert result["s1c"] == "S01-002"
    assert result["s2a"] == "S02-001"
    assert result["s2b"] == "S02-002"


def test_a_take_without_a_time_is_an_error():
    take = make_take("x", 5, 5)
    del take["createdAt"]
    with pytest.raises(ValueError):
        sittings.assign_sittings([take])


def test_bootstrap_is_deterministic():
    data = [(3.0, 4.0), (1.0, 5.0), (4.0, 4.0), (2.0, 3.0)]
    first = sittings.bootstrap_ratio_ci(data)
    second = sittings.bootstrap_ratio_ci(data)
    assert first == second
    assert first["seed"] == 12345 and first["n_resamples"] == 10000 and first["level"] == 0.95
    assert first["lower"] <= first["estimate"] <= first["upper"]
    assert first["estimate"] == pytest.approx(10 / 16)


def test_a_different_seed_changes_the_interval():
    data = [(float(i % 5), float(3 + i % 4)) for i in range(25)]
    default = sittings.bootstrap_ratio_ci(data)
    other = sittings.bootstrap_ratio_ci(data, seed=1)
    assert (default["lower"], default["upper"]) != (other["lower"], other["upper"])


def test_bootstrap_with_known_outcomes():
    # Two sittings with mean 0 and 1: resampled means are 0, 0.5 or 1.
    result = sittings.bootstrap_ratio_ci([(0.0, 1.0), (1.0, 1.0)])
    assert result["estimate"] == 0.5
    assert result["lower"] == 0.0
    assert result["upper"] == 1.0
    assert sittings.bootstrap_ratio_ci([(1.0, 1.0), (1.0, 1.0)])["lower"] == 1.0


def test_scale_multiplies_the_ratio():
    result = sittings.bootstrap_ratio_ci([(1.0, 2.0), (1.0, 2.0)], scale=10)
    assert result["estimate"] == pytest.approx(5.0)


def test_fewer_than_two_sittings_has_no_interval():
    result = sittings.bootstrap_ratio_ci([(3.0, 4.0)])
    assert result["estimate"] == pytest.approx(0.75)
    assert result["lower"] is None and result["upper"] is None
    assert "cannot be estimated" in result["note"]
    assert sittings.format_interval(result) == "n/a"


def test_no_data_has_no_estimate():
    result = sittings.bootstrap_ratio_ci([])
    assert result["estimate"] is None and result["lower"] is None


def sixteen(subject, count):
    """`count` takes of `subject`, each in its own sitting (one per day)."""
    return [at(subject, f"{subject}-t{i}", "09:00", day=f"2026-07-{i + 1:02d}") for i in range(count)]


def test_splits_last_three_s01_sittings_are_test():
    takes = sixteen("S01", 5)
    splits, warnings = sittings.assign_splits(takes)
    assert splits == {
        "S01-001": "dev", "S01-002": "dev",
        "S01-003": "test", "S01-004": "test", "S01-005": "test",
    }
    assert warnings == []


def test_splits_s01_with_three_or_fewer_sittings_is_all_dev_with_a_warning():
    splits, warnings = sittings.assign_splits(sixteen("S01", 3))
    assert set(splits.values()) == {"dev"}
    assert len(warnings) == 1 and "test set is empty" in warnings[0]


def test_splits_other_subjects_are_test_and_syn_is_dev():
    takes = sixteen("S01", 4) + sixteen("S02", 2) + sixteen("SYN", 2)
    splits, _ = sittings.assign_splits(takes)
    assert splits["S01-001"] == "dev"
    assert splits["S01-002"] == splits["S01-003"] == splits["S01-004"] == "test"
    assert splits["S02-001"] == splits["S02-002"] == "test"
    assert splits["SYN-001"] == splits["SYN-002"] == "dev"


def test_take_id_overrides_the_sitting_split():
    takes = [at("S01", "a", "09:00"), at("S01", "b", "09:10")]
    by_sitting = sittings.assign_sittings(takes)
    splits = {"S01-001": "dev", "b": "test"}
    assert sittings.split_of(takes[0], by_sitting, splits) == "dev"
    assert sittings.split_of(takes[1], by_sitting, splits) == "test"
    assert sittings.split_of(takes[0], by_sitting, {}) is None


def test_make_splits_cli_writes_the_file(tmp_path, capsys):
    predictions = make_predictions(sixteen("S01", 3) + sixteen("S02", 1))
    source = tmp_path / "predictions.json"
    source.write_text(json.dumps(predictions))
    out = tmp_path / "nested" / "splits.json"
    assert make_splits.main(["--predictions", str(source), "--out", str(out)]) == 0
    assert json.loads(out.read_text()) == {"S01-001": "dev", "S01-002": "dev", "S01-003": "dev", "S02-001": "test"}
    assert "test set is empty" in capsys.readouterr().err
