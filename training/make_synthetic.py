"""
Generate synthetic pose-recording sessions in the same JSON format the iOS
app produces, so the rest of the pipeline (train.py, evaluate.py) can be
exercised end-to-end before any real recordings exist.

The synthetic poses are deliberately simple parametric stick figures, not
a physics simulation: "up"/"down" sessions place the body roughly
horizontal with the elbow angle near straight/bent respectively, and
"not_pushup" sessions place the body roughly upright (standing) with a
random elbow pose. This gives the classifier three separable classes
without needing any real recordings.

Usage:
    python make_synthetic.py [--out data/raw] [--per-class 10] [--seed 42]
"""

import argparse
import json
import math
import random
from pathlib import Path

JOINT_NAMES = (
    "nose",
    "neck",
    "leftShoulder",
    "rightShoulder",
    "leftElbow",
    "rightElbow",
    "leftWrist",
    "rightWrist",
    "leftHip",
    "rightHip",
    "root",
    "leftKnee",
    "rightKnee",
    "leftAnkle",
    "rightAnkle",
)

FRAME_DT = 1.0 / 30.0  # 30 fps


def _clip01(v):
    return max(0.0, min(1.0, v))


def _rand_conf(rng, low=0.55, high=0.98, drop_prob=0.03):
    """Most frames have solid confidence; occasionally simulate a flaky detection."""
    if rng.random() < drop_prob:
        return round(rng.uniform(0.0, 0.29), 3)
    return round(rng.uniform(low, high), 3)


def _rotate(vx, vy, theta):
    c, s = math.cos(theta), math.sin(theta)
    return vx * c - vy * s, vx * s + vy * c


def _make_pushup_frame(rng, phase, hip_center, torso_theta, torso_len):
    """
    phase: 0.0 = fully down (elbow bent ~80deg), 1.0 = fully up (elbow ~170deg)
    torso_theta: orientation of the hip->shoulder vector (radians, 0 = pointing
        along +x, roughly horizontal, which is what a side-on pushup looks like)
    """
    elbow_angle_target = math.radians(80 + phase * 90)  # 80deg down -> 170deg up

    shoulder_half_width = 0.03 * torso_len / 0.3
    hip_half_width = 0.025 * torso_len / 0.3
    upper_arm_len = 0.14 * torso_len / 0.3
    forearm_len = 0.13 * torso_len / 0.3
    thigh_len = 0.16 * torso_len / 0.3
    shin_len = 0.15 * torso_len / 0.3

    hx, hy = hip_center
    dx, dy = math.cos(torso_theta), math.sin(torso_theta)
    shoulder_center = (hx + dx * torso_len, hy + dy * torso_len)

    perp = (-dy, dx)

    def offset(center, half_width, sign):
        return (center[0] + perp[0] * half_width * sign, center[1] + perp[1] * half_width * sign)

    left_shoulder = offset(shoulder_center, shoulder_half_width, 1)
    right_shoulder = offset(shoulder_center, shoulder_half_width, -1)
    left_hip = offset(hip_center, hip_half_width, 1)
    right_hip = offset(hip_center, hip_half_width, -1)

    # Arm points roughly toward the floor (perpendicular to the torso), then
    # bends at the elbow by `elbow_angle_target`.
    arm_dir = torso_theta + math.pi / 2

    def arm_points(shoulder):
        ex = shoulder[0] + math.cos(arm_dir) * upper_arm_len
        ey = shoulder[1] + math.sin(arm_dir) * upper_arm_len
        wrist_dir = (arm_dir + math.pi) - elbow_angle_target
        wx = ex + math.cos(wrist_dir) * forearm_len
        wy = ey + math.sin(wrist_dir) * forearm_len
        return (ex, ey), (wx, wy)

    left_elbow, left_wrist = arm_points(left_shoulder)
    right_elbow, right_wrist = arm_points(right_shoulder)

    # Legs continue roughly straight along the torso direction (plank form),
    # with a little natural noise.
    leg_theta = torso_theta + rng.uniform(-0.05, 0.05)

    def leg_points(hip):
        kx = hip[0] + math.cos(leg_theta) * thigh_len
        ky = hip[1] + math.sin(leg_theta) * thigh_len
        ax = kx + math.cos(leg_theta) * shin_len
        ay = ky + math.sin(leg_theta) * shin_len
        return (kx, ky), (ax, ay)

    left_knee, left_ankle = leg_points(left_hip)
    right_knee, right_ankle = leg_points(right_hip)

    head_dir = torso_theta + math.pi
    neck = shoulder_center
    nose = (
        shoulder_center[0] + math.cos(head_dir) * upper_arm_len * 0.6,
        shoulder_center[1] + math.sin(head_dir) * upper_arm_len * 0.6,
    )
    root = hip_center

    points = {
        "nose": nose,
        "neck": neck,
        "leftShoulder": left_shoulder,
        "rightShoulder": right_shoulder,
        "leftElbow": left_elbow,
        "rightElbow": right_elbow,
        "leftWrist": left_wrist,
        "rightWrist": right_wrist,
        "leftHip": left_hip,
        "rightHip": right_hip,
        "root": root,
        "leftKnee": left_knee,
        "rightKnee": right_knee,
        "leftAnkle": left_ankle,
        "rightAnkle": right_ankle,
    }
    return points


def _make_standing_frame(rng, hip_center, torso_theta, torso_len):
    """A rough standing/sitting/idle pose used for the not_pushup class."""
    shoulder_half_width = 0.03 * torso_len / 0.3
    hip_half_width = 0.025 * torso_len / 0.3
    upper_arm_len = 0.14 * torso_len / 0.3
    forearm_len = 0.13 * torso_len / 0.3
    thigh_len = 0.16 * torso_len / 0.3
    shin_len = 0.15 * torso_len / 0.3

    hx, hy = hip_center
    dx, dy = math.cos(torso_theta), math.sin(torso_theta)
    shoulder_center = (hx + dx * torso_len, hy + dy * torso_len)
    perp = (-dy, dx)

    def offset(center, half_width, sign):
        return (center[0] + perp[0] * half_width * sign, center[1] + perp[1] * half_width * sign)

    left_shoulder = offset(shoulder_center, shoulder_half_width, 1)
    right_shoulder = offset(shoulder_center, shoulder_half_width, -1)
    left_hip = offset(hip_center, hip_half_width, 1)
    right_hip = offset(hip_center, hip_half_width, -1)

    # Arms hang or gesture at a random angle -- nothing pushup-like.
    def arm_points(shoulder):
        arm_dir = rng.uniform(0, 2 * math.pi)
        elbow_bend = rng.uniform(math.radians(40), math.radians(175))
        ex = shoulder[0] + math.cos(arm_dir) * upper_arm_len
        ey = shoulder[1] + math.sin(arm_dir) * upper_arm_len
        wrist_dir = (arm_dir + math.pi) - elbow_bend
        wx = ex + math.cos(wrist_dir) * forearm_len
        wy = ey + math.sin(wrist_dir) * forearm_len
        return (ex, ey), (wx, wy)

    left_elbow, left_wrist = arm_points(left_shoulder)
    right_elbow, right_wrist = arm_points(right_shoulder)

    # Legs continue roughly along torso direction with some bend (standing
    # or sitting), independent per side for a bit of asymmetry.
    def leg_points(hip):
        leg_theta = torso_theta + rng.uniform(-0.35, 0.35)
        kx = hip[0] + math.cos(leg_theta) * thigh_len
        ky = hip[1] + math.sin(leg_theta) * thigh_len
        shin_theta = leg_theta + rng.uniform(-0.3, 0.3)
        ax = kx + math.cos(shin_theta) * shin_len
        ay = ky + math.sin(shin_theta) * shin_len
        return (kx, ky), (ax, ay)

    left_knee, left_ankle = leg_points(left_hip)
    right_knee, right_ankle = leg_points(right_hip)

    head_dir = torso_theta + math.pi
    neck = shoulder_center
    nose = (
        shoulder_center[0] + math.cos(head_dir) * upper_arm_len * 0.6,
        shoulder_center[1] + math.sin(head_dir) * upper_arm_len * 0.6,
    )
    root = hip_center

    return {
        "nose": nose,
        "neck": neck,
        "leftShoulder": left_shoulder,
        "rightShoulder": right_shoulder,
        "leftElbow": left_elbow,
        "rightElbow": right_elbow,
        "leftWrist": left_wrist,
        "rightWrist": right_wrist,
        "leftHip": left_hip,
        "rightHip": right_hip,
        "root": root,
        "leftKnee": left_knee,
        "rightKnee": right_knee,
        "leftAnkle": left_ankle,
        "rightAnkle": right_ankle,
    }


def _points_to_joints(points, rng, image_center, jitter=0.01):
    joints = {}
    cx, cy = image_center
    for name in JOINT_NAMES:
        x, y = points[name]
        x = _clip01(x + cx + rng.uniform(-jitter, jitter))
        y = _clip01(y + cy + rng.uniform(-jitter, jitter))
        c = _rand_conf(rng)
        joints[name] = [round(x, 4), round(y, 4), c]
    return joints


def generate_pushup_session(label, rng, n_frames):
    assert label in ("up", "down")
    phase_center = 1.0 if label == "up" else 0.0

    torso_len = rng.uniform(0.22, 0.32)
    torso_theta = rng.uniform(-0.12, 0.12)  # roughly horizontal, small camera-angle noise
    image_cx = rng.uniform(0.35, 0.55)
    image_cy = rng.uniform(0.35, 0.55)
    hip_center = (-torso_len / 2, 0.0)  # local frame; recentered by _points_to_joints

    frames = []
    t = 0.0
    for _ in range(n_frames):
        phase = _clip01(phase_center + rng.uniform(-0.08, 0.08))
        this_theta = torso_theta + rng.uniform(-0.02, 0.02)
        points = _make_pushup_frame(rng, phase, hip_center, this_theta, torso_len)
        joints = _points_to_joints(points, rng, (image_cx, image_cy))
        frames.append({"t": round(t, 4), "joints": joints})
        t += FRAME_DT

    return {
        "label": label,
        "source": f"synthetic-generator pushup phase={label}",
        "frames": frames,
    }


def generate_not_pushup_session(rng, n_frames):
    torso_len = rng.uniform(0.28, 0.42)
    # Roughly upright, i.e. hip->shoulder vector points mostly "up" the
    # image (negative y), with a lot of noise so this class stays diverse.
    torso_theta = -math.pi / 2 + rng.uniform(-0.4, 0.4)
    image_cx = rng.uniform(0.3, 0.6)
    image_cy = rng.uniform(0.4, 0.65)
    hip_center = (0.0, torso_len / 2)

    frames = []
    t = 0.0
    for _ in range(n_frames):
        this_theta = torso_theta + rng.uniform(-0.08, 0.08)
        points = _make_standing_frame(rng, hip_center, this_theta, torso_len)
        joints = _points_to_joints(points, rng, (image_cx, image_cy))
        frames.append({"t": round(t, 4), "joints": joints})
        t += FRAME_DT

    return {
        "label": "not_pushup",
        "source": "synthetic-generator idle/standing",
        "frames": frames,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", default="data/raw", help="Output directory for session JSON files")
    parser.add_argument("--per-class", type=int, default=10, help="Number of sessions to generate per class")
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--min-frames", type=int, default=45)
    parser.add_argument("--max-frames", type=int, default=110)
    args = parser.parse_args()

    out_dir = Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)

    rng = random.Random(args.seed)
    written = 0

    for label in ("up", "down"):
        for i in range(args.per_class):
            n_frames = rng.randint(args.min_frames, args.max_frames)
            session = generate_pushup_session(label, rng, n_frames)
            path = out_dir / f"synthetic_{label}_{i:03d}.json"
            with open(path, "w") as f:
                json.dump(session, f)
            written += 1

    for i in range(args.per_class):
        n_frames = rng.randint(args.min_frames, args.max_frames)
        session = generate_not_pushup_session(rng, n_frames)
        path = out_dir / f"synthetic_not_pushup_{i:03d}.json"
        with open(path, "w") as f:
            json.dump(session, f)
        written += 1

    print(f"Wrote {written} synthetic sessions to {out_dir}/")


if __name__ == "__main__":
    main()
