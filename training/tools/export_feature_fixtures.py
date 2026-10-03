"""
Export golden feature-vector fixtures for the Swift/Python parity test.

Runs `extract_features` from training/features.py over a fixed set of poses
(hand-built plus seeded random) and writes the inputs and expected 25-dim
outputs to the JSON file the Swift package's `FeatureParityTests` reads.

Run from the training directory (standard library only, fixed seed, so the
output is reproducible):

    cd training
    .venv/bin/python tools/export_feature_fixtures.py

Case format: {"name": str, "joints": {jointName: [x, y, confidence]},
"expected": [25 floats] or null (frame rejected by the extractor)}.
"""

import json
import math
import random
import sys
from pathlib import Path

TRAINING_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(TRAINING_DIR))

from features import FEATURE_DIM, JOINT_NAMES, extract_features  # noqa: E402

OUT_PATH = (
    TRAINING_DIR.parent
    / "Packages"
    / "PushupCore"
    / "Tests"
    / "PushupCoreTests"
    / "Fixtures"
    / "feature_parity_v1.json"
)

SEED = 20260714

GATE_JOINTS = (
    "leftShoulder",
    "rightShoulder",
    "leftElbow",
    "rightElbow",
    "leftWrist",
    "rightWrist",
    "leftHip",
    "rightHip",
)


def front_pose(elbow_deg, lean=0.0, conf=0.9, scale=1.0, origin=(0.5, 0.3)):
    """
    A front-view pose in image convention (y up): hips low, shoulders above,
    wrists planted below the shoulders, elbows placed so the angle at the
    elbow equals `elbow_deg`. `lean` shifts the shoulders sideways (negative
    values put the shoulder centre left of the hip centre, which flips the
    mirror normalisation).
    """
    ox, oy = origin
    torso = 0.30 * scale
    sw = 0.09 * scale  # shoulder half width
    hw = 0.07 * scale  # hip half width
    upper = 0.14 * scale
    fore = 0.13 * scale

    sx, sy = ox + lean * scale, oy + torso

    def arm(sign):
        shoulder = (sx + sign * sw, sy)
        # Upper arm hangs down and outward; forearm turned by the elbow angle.
        out = math.radians(25) * sign
        elbow = (
            shoulder[0] + math.sin(out) * upper,
            shoulder[1] - math.cos(out) * upper,
        )
        back = math.atan2(shoulder[1] - elbow[1], shoulder[0] - elbow[0])
        theta = math.radians(elbow_deg)
        wrist_dir = back + sign * theta
        wrist = (elbow[0] + math.cos(wrist_dir) * fore, elbow[1] + math.sin(wrist_dir) * fore)
        return shoulder, elbow, wrist

    ls, le, lw = arm(-1)
    rs, re, rw = arm(1)
    lh = (ox - hw, oy)
    rh = (ox + hw, oy)
    joints = {
        "nose": (sx, sy + 0.08 * scale),
        "neck": (sx, sy),
        "leftShoulder": ls,
        "rightShoulder": rs,
        "leftElbow": le,
        "rightElbow": re,
        "leftWrist": lw,
        "rightWrist": rw,
        "leftHip": lh,
        "rightHip": rh,
        "root": (ox, oy),
        "leftKnee": (ox - hw, oy - 0.16 * scale),
        "rightKnee": (ox + hw, oy - 0.16 * scale),
        "leftAnkle": (ox - hw, oy - 0.31 * scale),
        "rightAnkle": (ox + hw, oy - 0.31 * scale),
    }
    return {k: [round(v[0], 6), round(v[1], 6), conf] for k, v in joints.items()}


def case(name, joints):
    return {"name": name, "joints": joints, "expected": extract_features(joints)}


def build_cases():
    cases = []

    # Plausible up, mid and down poses, both mirror orientations.
    for deg in (170, 160, 145, 130, 120, 100, 85, 70):
        cases.append(case(f"pose_elbow{deg}_right_lean", front_pose(deg, lean=0.04)))
        cases.append(case(f"pose_elbow{deg}_left_lean", front_pose(deg, lean=-0.04)))

    cases.append(case("pose_small_far_from_camera", front_pose(150, scale=0.5, origin=(0.3, 0.2))))
    cases.append(case("pose_large_close_to_camera", front_pose(100, scale=1.6, origin=(0.6, 0.15))))
    cases.append(case("pose_straight_up_no_lean", front_pose(165, lean=0.0)))

    # Ankles: missing, low confidence, exactly at the threshold, mixed.
    base = front_pose(140, lean=0.03)
    for side in ("left", "right"):
        j = dict(base)
        del j[f"{side}Ankle"]
        cases.append(case(f"ankle_missing_{side}", j))
    j = dict(base)
    del j["leftAnkle"], j["rightAnkle"]
    cases.append(case("ankle_missing_both", j))
    j = dict(base)
    j["leftAnkle"] = [j["leftAnkle"][0], j["leftAnkle"][1], 0.1]
    j["rightAnkle"] = [j["rightAnkle"][0], j["rightAnkle"][1], 0.1]
    cases.append(case("ankle_low_conf_both", j))
    j = dict(base)
    j["leftAnkle"] = [j["leftAnkle"][0], j["leftAnkle"][1], 0.0]
    cases.append(case("ankle_zero_conf_left_only", j))
    j = dict(base)
    j["rightAnkle"] = [j["rightAnkle"][0], j["rightAnkle"][1], 0.3]
    cases.append(case("ankle_conf_exactly_threshold_right", j))
    j = dict(base)
    j["rightAnkle"] = [j["rightAnkle"][0], j["rightAnkle"][1], 0.2999]
    cases.append(case("ankle_conf_just_below_threshold_right", j))
    j = dict(base)
    for name in ("nose", "leftKnee", "rightKnee", "leftAnkle", "rightAnkle"):
        del j[name]
    cases.append(case("optional_joints_all_missing", j))

    # A missing gate joint rejects the frame.
    for name in GATE_JOINTS:
        j = front_pose(150)
        del j[name]
        cases.append(case(f"gate_joint_missing_{name}", j))

    # Neck / root missing: passes the gate but fails the core-joint check.
    for name in ("neck", "root"):
        j = front_pose(150)
        del j[name]
        cases.append(case(f"core_joint_missing_{name}", j))

    # Low mean confidence.
    cases.append(case("low_mean_conf_all_0.2", front_pose(150, conf=0.2)))
    cases.append(case("low_mean_conf_all_0.0", front_pose(150, conf=0.0)))
    j = front_pose(150)
    for name in GATE_JOINTS[:5]:
        j[name][2] = 0.1
    cases.append(case("low_mean_conf_five_of_eight_0.1", j))
    j = front_pose(150)
    j["leftWrist"][2] = 0.0  # one dead joint, mean still above the gate
    cases.append(case("one_dead_gate_joint_mean_ok", j))
    cases.append(case("mean_conf_just_above_gate_0.31", front_pose(150, conf=0.31)))
    cases.append(case("mean_conf_just_below_gate_0.29", front_pose(150, conf=0.29)))

    # Degenerate torso.
    j = front_pose(150)
    j["leftShoulder"] = list(j["leftHip"])
    j["rightShoulder"] = list(j["rightHip"])
    cases.append(case("degenerate_zero_torso", j))
    j = front_pose(150)
    for name in ("leftShoulder", "rightShoulder"):
        j[name][0] = 0.5
        j[name][1] = 0.3
    for name in ("leftHip", "rightHip"):
        j[name][0] = 0.5
        j[name][1] = 0.3
    cases.append(case("degenerate_all_torso_joints_coincide", j))
    j = front_pose(150)
    j["leftShoulder"][1] = j["leftHip"][1] + 1e-8
    j["rightShoulder"][1] = j["rightHip"][1] + 1e-8
    j["leftShoulder"][0] = j["leftHip"][0]
    j["rightShoulder"][0] = j["rightHip"][0]
    cases.append(case("degenerate_tiny_torso_below_eps", j))

    # Degenerate arm geometry: elbow on top of shoulder gives angle 0.
    j = front_pose(150)
    j["leftElbow"][0], j["leftElbow"][1] = j["leftShoulder"][0], j["leftShoulder"][1]
    cases.append(case("degenerate_left_elbow_on_shoulder", j))

    # Horizontal torso (side-on) and upside-down torso.
    j = front_pose(150)
    for name in j:
        x, y, c = j[name]
        j[name] = [round(0.5 + (y - 0.3), 6), round(0.3 + (x - 0.5), 6), c]
    cases.append(case("torso_rotated_horizontal", j))
    j = front_pose(150)
    for name in j:
        x, y, c = j[name]
        j[name] = [x, round(0.6 - (y - 0.3), 6), c]
    cases.append(case("torso_flipped_upside_down", j))

    # Seeded random poses: random positions and confidences.
    rng = random.Random(SEED)
    for i in range(30):
        joints = {}
        for name in JOINT_NAMES:
            joints[name] = [
                round(rng.uniform(0.0, 1.0), 6),
                round(rng.uniform(0.0, 1.0), 6),
                round(rng.uniform(0.2, 1.0), 4),
            ]
        # Randomly drop some optional joints.
        for name in ("nose", "leftKnee", "rightKnee", "leftAnkle", "rightAnkle"):
            if rng.random() < 0.3:
                del joints[name]
        cases.append(case(f"random_free_{i:02d}", joints))

    # Seeded random plausible poses: jittered pushup pose.
    for i in range(20):
        deg = rng.uniform(60, 175)
        lean = rng.uniform(-0.08, 0.08)
        scale = rng.uniform(0.5, 1.5)
        origin = (rng.uniform(0.3, 0.7), rng.uniform(0.15, 0.4))
        joints = front_pose(deg, lean=lean, scale=scale, origin=origin)
        for name in joints:
            joints[name][0] = round(joints[name][0] + rng.gauss(0, 0.004), 6)
            joints[name][1] = round(joints[name][1] + rng.gauss(0, 0.004), 6)
            joints[name][2] = round(rng.uniform(0.4, 1.0), 4)
        cases.append(case(f"random_plausible_{i:02d}", joints))

    return cases


def main():
    cases = build_cases()
    for c in cases:
        if c["expected"] is not None:
            assert len(c["expected"]) == FEATURE_DIM
    OUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    with open(OUT_PATH, "w") as f:
        json.dump(cases, f, indent=1)
        f.write("\n")
    nulls = sum(1 for c in cases if c["expected"] is None)
    print(f"wrote {len(cases)} cases ({nulls} expected null) to {OUT_PATH}")


if __name__ == "__main__":
    main()
