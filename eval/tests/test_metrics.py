import pytest

from helpers import make_take
from pushup_report import metrics

ALPHA = 0.1


def valid_fixture():
    return [
        make_take("a", 5, 5),
        make_take("b", 8, 7),
        make_take("c", 0, 2),  # zero true reps: the normalised error needs alpha
        make_take("d", 10, 13),
        # None of these is a valid set.
        make_take("cheat", 0, 4, cheat="half_reps"),
        make_take("neg", 0, 3, kind="negative"),
        make_take("pose", None, 0, kind="pose"),
    ]


def test_valid_set_metrics_match_hand_computation():
    result = metrics.valid_set_metrics(valid_fixture())
    assert result["n_takes"] == 4
    assert result["alpha"] == ALPHA
    assert result["exact_count_accuracy"] == pytest.approx(1 / 4)
    assert result["off_by_one_accuracy"] == pytest.approx(2 / 4)
    assert result["mae"] == pytest.approx((0 + 1 + 2 + 3) / 4)
    expected_nmae = (0 / 5.1 + 1 / 8.1 + 2 / 0.1 + 3 / 10.1) / 4
    assert result["normalised_mae"] == pytest.approx(expected_nmae)
    assert result["signed_bias"] == pytest.approx((0 - 1 + 2 + 3) / 4)
    assert result["total_true_reps"] == 23
    assert result["total_predicted_reps"] == 27


def test_zero_true_rep_valid_set_is_defined():
    result = metrics.valid_set_metrics([make_take("z", 0, 1)])
    assert result["normalised_mae"] == pytest.approx(1 / 0.1)


def test_alpha_is_a_parameter():
    result = metrics.valid_set_metrics([make_take("z", 0, 1)], alpha=1.0)
    assert result["normalised_mae"] == pytest.approx(1.0)
    assert result["alpha"] == 1.0


def test_undercounting_gives_negative_bias():
    result = metrics.valid_set_metrics([make_take("u", 10, 7)])
    assert result["signed_bias"] == -3


def test_no_valid_sets_gives_none():
    result = metrics.valid_set_metrics([make_take("n", 0, 0, kind="negative")])
    assert result["n_takes"] == 0
    assert result["exact_count_accuracy"] is None
    assert result["total_true_reps"] == 0


def test_cheat_metrics_including_a_mixed_set():
    takes = [
        make_take("h1", 0, 0, cheat="half_reps"),
        make_take("h2", 0, 2, cheat="half_reps"),
        make_take("w1", 0, 1, cheat="arm_wave"),
        make_take("m1", 6, 4, cheat="half_reps"),  # undercount: awarded 0, missed 2
        make_take("m2", 5, 7, cheat="half_reps"),  # overcount: awarded 2, missed 0
        make_take("ok", 5, 5),  # valid, not a cheat
    ]
    result = metrics.cheat_metrics(takes)

    overall = result["overall"]
    assert overall["n_takes"] == 5
    assert overall["spoof_acceptance_rate"] == pytest.approx(3 / 5)
    assert overall["mean_awarded_reps"] == pytest.approx((0 + 2 + 1 + 0 + 2) / 5)
    assert overall["n_mixed_takes"] == 2
    assert overall["missed_valid_reps"] == 2

    half = result["by_type"]["half_reps"]
    assert half["n_takes"] == 4
    assert half["spoof_acceptance_rate"] == pytest.approx(2 / 4)
    assert half["mean_awarded_reps"] == pytest.approx(1.0)
    assert half["missed_valid_reps"] == 2

    wave = result["by_type"]["arm_wave"]
    assert wave["n_takes"] == 1
    assert wave["spoof_acceptance_rate"] == 1.0
    assert wave["n_mixed_takes"] == 0
    assert wave["missed_valid_reps_per_mixed_take"] is None


def test_awarded_and_missed_helpers():
    assert metrics.awarded_reps(make_take("a", 3, 5, cheat="other")) == 2
    assert metrics.awarded_reps(make_take("b", 3, 1, cheat="other")) == 0
    assert metrics.missed_valid_reps(make_take("c", 3, 1, cheat="other")) == 2
    assert metrics.missed_valid_reps(make_take("d", 3, 5, cheat="other")) == 0


def test_negatives_per_minute_and_fraction():
    takes = [
        make_take("n1", 0, 0, kind="negative", duration=30),
        make_take("n2", 0, 3, kind="negative", duration=90),
        make_take("set", 5, 5),
    ]
    result = metrics.negative_metrics(takes)
    assert result["n_clips"] == 2
    assert result["total_minutes"] == pytest.approx(2.0)
    assert result["false_reps"] == 3
    assert result["false_reps_per_minute"] == pytest.approx(1.5)
    assert result["fraction_with_false_rep"] == pytest.approx(0.5)


def test_negatives_without_clips():
    result = metrics.negative_metrics([make_take("a", 5, 5)])
    assert result["n_clips"] == 0
    assert result["false_reps_per_minute"] is None
    assert result["fraction_with_false_rep"] is None


def test_fidelity_uses_only_matching_classifier_takes():
    takes = [
        make_take("m", 5, 5, live={"reps": 5, "rejectedReps": 0, "classifier": "heuristic"}),
        make_take("x", 5, 5, live={"reps": 4, "rejectedReps": 0, "classifier": "heuristic"}),
        make_take("c", 5, 5, live={"reps": 9, "rejectedReps": 0, "classifier": "coreml"}),
        make_take("n", 5, 5),
    ]
    result = metrics.replay_fidelity(takes, "heuristic")
    assert result == {"n_eligible": 2, "n_match": 1, "fidelity": 0.5}


def test_fidelity_without_a_live_block():
    result = metrics.replay_fidelity([make_take("n", 5, 5)], "heuristic")
    assert result["n_eligible"] == 0
    assert result["fidelity"] is None


def test_group_metrics_by_lighting_and_subject():
    takes = [
        make_take("a", 5, 5, lighting="dim", subject="S01"),
        make_take("b", 8, 6, lighting="dim", subject="S02"),
        make_take("c", 4, 4, lighting="daylight", subject="S01"),
        make_take("cheat", 0, 3, lighting="daylight", cheat="half_reps"),
    ]
    by_light = metrics.group_metrics(takes, "lighting")
    assert set(by_light) == {"dim", "daylight"}
    assert by_light["dim"]["n_takes"] == 2
    assert by_light["dim"]["n_reps"] == 13
    assert by_light["dim"]["exact_count_accuracy"] == pytest.approx(0.5)
    assert by_light["daylight"]["n_takes"] == 1

    by_subject = metrics.group_metrics(takes, "subject")
    assert by_subject["S01"]["n_takes"] == 2
    assert by_subject["S02"]["mae"] == pytest.approx(2.0)


def test_condition_tables_cover_every_key():
    tables = metrics.condition_tables([make_take("a", 5, 5)])
    assert set(tables) == {"lighting", "distance", "clothing", "tempo", "variant", "subject"}


def test_worst_takes_are_ranked_and_limited():
    takes = [make_take(f"t{i:02d}", 10, 10 + i) for i in range(12)]
    takes.append(make_take("cheat", 0, 50, cheat="half_reps"))
    worst = metrics.worst_takes(takes)
    assert len(worst) == 10
    assert worst[0]["file"] == "t11.json"
    assert worst[0]["true"] == 10 and worst[0]["predicted"] == 21
    assert worst[0]["tags"]["cheat"] == "none"
    assert [w["file"] for w in worst][-1] == "t02.json"


def test_worst_takes_leave_out_exact_counts():
    takes = [make_take("exact", 6, 6), make_take("off", 6, 5), make_take("cheat", 0, 9, cheat="half_reps")]
    assert [w["file"] for w in metrics.worst_takes(takes)] == ["off.json"]


def test_worst_takes_are_empty_when_every_set_is_exact():
    takes = [make_take("a", 5, 5), make_take("b", 0, 0), make_take("n", 0, 3, kind="negative")]
    assert metrics.worst_takes(takes) == []
