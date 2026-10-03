"""
Feature extraction for the pushup pose classifier.

This is the single source of truth for turning one raw pose frame (as
recorded by the iOS app from Apple Vision's VNHumanBodyPoseObservation)
into the fixed-length numeric vector the models are trained on.

If you change anything in here, mirror the exact same logic on the Swift
side before shipping a new model, otherwise on-device inference will not
match what the model was trained on.

--------------------------------------------------------------------------
Input contract (one frame)
--------------------------------------------------------------------------
`joints` is a dict: joint name -> [x, y, confidence]
  - x, y are normalized image coordinates in [0, 1]
  - confidence is in [0, 1]

Recognized joint names (Apple Vision body-pose subset used by this app):
    nose, neck,
    leftShoulder, rightShoulder,
    leftElbow, rightElbow,
    leftWrist, rightWrist,
    leftHip, rightHip,
    root,
    leftKnee, rightKnee,
    leftAnkle, rightAnkle

A joint may be missing from the dict entirely (Vision did not detect it
for that frame); treat that the same as "not confident enough".

--------------------------------------------------------------------------
Algorithm
--------------------------------------------------------------------------
1. Confidence gate: compute the mean confidence of the eight "core" arm
   and torso joints (shoulders, elbows, wrists, hips). If it is below
   0.3, the frame is unusable -> return None.

2. Normalize:
   a. hip_center   = mean(leftHip, rightHip)               (x, y)
   b. shoulder_center = mean(leftShoulder, rightShoulder)  (x, y)
   c. torso_length = euclidean distance(hip_center, shoulder_center)
   d. Translate every joint so hip_center becomes the origin.
   e. Scale every joint by 1 / torso_length, so torso_length becomes 1.
   f. Mirror-normalize: if (shoulder_center.x - hip_center.x) < 0 (i.e.
      the body is facing/leaning the other way on screen), flip the sign
      of every joint's x coordinate. This makes the feature space
      orientation-invariant to which way the person is facing the camera.

3. Feature vector (25 dims, float32), in this exact order:
   [0:20]  normalized (x, y) pairs for the 10 "core" joints, in order:
           leftShoulder, rightShoulder, leftElbow, rightElbow,
           leftWrist, rightWrist, leftHip, rightHip, neck, root
   [20]    left elbow angle  (angle at leftElbow between leftShoulder and leftWrist)
   [21]    right elbow angle (angle at rightElbow between rightShoulder and rightWrist)
   [22]    left body-line angle  (angle at leftHip between leftShoulder and
           leftAnkle if the ankle is confident enough, else the angle
           between the leftShoulder->leftHip vector and the horizontal)
   [23]    right body-line angle (same, right side)
   [24]    torso-vs-horizontal angle (angle between the hip_center ->
           shoulder_center vector and the horizontal, post-normalization)

   All angles are in radians, range [0, pi].

See FEATURE_NAMES below for the exact per-index labels, and FEATURE_DIM
(25) for the vector length. FEATURE_VERSION should be bumped any time the
extraction logic changes in a way that makes old exported models
incompatible with new feature vectors (and vice versa).
"""

import math

FEATURE_VERSION = "v1"

# All joint names this pipeline understands, as produced by the iOS app.
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

# Joints whose mean confidence gates whether a frame is usable at all.
_CONF_CHECK_JOINTS = (
    "leftShoulder",
    "rightShoulder",
    "leftElbow",
    "rightElbow",
    "leftWrist",
    "rightWrist",
    "leftHip",
    "rightHip",
)
_MIN_MEAN_CONFIDENCE = 0.3

# Confidence threshold for using the ankle in the body-line angle instead
# of falling back to shoulder-hip-vs-horizontal.
_ANKLE_CONF_THRESHOLD = 0.3

_EPS = 1e-6

# The 10 joints whose normalized (x, y) make up the first 20 feature dims,
# in this exact order.
_CORE_JOINTS = (
    "leftShoulder",
    "rightShoulder",
    "leftElbow",
    "rightElbow",
    "leftWrist",
    "rightWrist",
    "leftHip",
    "rightHip",
    "neck",
    "root",
)

FEATURE_NAMES = tuple(
    f"{joint}.{axis}" for joint in _CORE_JOINTS for axis in ("x", "y")
) + (
    "leftElbowAngle",
    "rightElbowAngle",
    "leftBodyLineAngle",
    "rightBodyLineAngle",
    "torsoHorizontalAngle",
)

FEATURE_DIM = len(FEATURE_NAMES)  # 25


def _get(joints, name):
    """Return (x, y, confidence) for a named joint, or None if absent/malformed."""
    v = joints.get(name)
    if v is None or len(v) < 3:
        return None
    return float(v[0]), float(v[1]), float(v[2])


def _mean_point(joints, names):
    pts = []
    for n in names:
        v = _get(joints, n)
        if v is None:
            return None
        pts.append((v[0], v[1]))
    xs = sum(p[0] for p in pts) / len(pts)
    ys = sum(p[1] for p in pts) / len(pts)
    return xs, ys


def _vec_angle_to_horizontal(v):
    """Angle in [0, pi] between vector v=(x, y) and the positive-x horizontal axis."""
    norm = math.hypot(v[0], v[1])
    if norm < _EPS:
        return 0.0
    cos_a = max(-1.0, min(1.0, v[0] / norm))
    return math.acos(cos_a)


def _angle_at_vertex(vertex, a, b):
    """Angle in [0, pi] at point `vertex`, between rays vertex->a and vertex->b."""
    v1 = (a[0] - vertex[0], a[1] - vertex[1])
    v2 = (b[0] - vertex[0], b[1] - vertex[1])
    n1 = math.hypot(*v1)
    n2 = math.hypot(*v2)
    if n1 < _EPS or n2 < _EPS:
        return 0.0
    dot = v1[0] * v2[0] + v1[1] * v2[1]
    cos_a = max(-1.0, min(1.0, dot / (n1 * n2)))
    return math.acos(cos_a)


def extract_features(joints):
    """
    Convert one frame's `joints` dict (name -> [x, y, confidence]) into a
    25-dim list of floats (see module docstring for the exact layout), or
    return None if the frame does not pass the confidence gate / is
    missing joints required for normalization.
    """
    # 1. Confidence gate.
    confs = []
    for name in _CONF_CHECK_JOINTS:
        v = _get(joints, name)
        if v is None:
            return None
        confs.append(v[2])
    if sum(confs) / len(confs) < _MIN_MEAN_CONFIDENCE:
        return None

    hip_center = _mean_point(joints, ("leftHip", "rightHip"))
    shoulder_center = _mean_point(joints, ("leftShoulder", "rightShoulder"))
    if hip_center is None or shoulder_center is None:
        return None

    torso_length = math.hypot(
        shoulder_center[0] - hip_center[0], shoulder_center[1] - hip_center[1]
    )
    if torso_length < _EPS:
        return None

    mirror = -1.0 if (shoulder_center[0] - hip_center[0]) < 0 else 1.0

    def norm_xy(name):
        v = _get(joints, name)
        if v is None:
            return None
        x = mirror * (v[0] - hip_center[0]) / torso_length
        y = (v[1] - hip_center[1]) / torso_length
        return x, y

    normalized = {}
    for name in JOINT_NAMES:
        p = norm_xy(name)
        if p is not None:
            normalized[name] = p

    # All 10 core joints must be present post-normalization.
    for name in _CORE_JOINTS:
        if name not in normalized:
            return None

    feats = []
    for name in _CORE_JOINTS:
        x, y = normalized[name]
        feats.append(x)
        feats.append(y)

    def elbow_angle(shoulder, elbow, wrist):
        if elbow not in normalized or shoulder not in normalized or wrist not in normalized:
            return 0.0
        return _angle_at_vertex(normalized[elbow], normalized[shoulder], normalized[wrist])

    feats.append(elbow_angle("leftShoulder", "leftElbow", "leftWrist"))
    feats.append(elbow_angle("rightShoulder", "rightElbow", "rightWrist"))

    def body_line_angle(side):
        shoulder = f"{side}Shoulder"
        hip = f"{side}Hip"
        ankle = f"{side}Ankle"
        if hip not in normalized or shoulder not in normalized:
            return 0.0
        raw_ankle = _get(joints, ankle)
        ankle_ok = (
            raw_ankle is not None
            and raw_ankle[2] >= _ANKLE_CONF_THRESHOLD
            and ankle in normalized
        )
        if ankle_ok:
            return _angle_at_vertex(normalized[hip], normalized[shoulder], normalized[ankle])
        v = (
            normalized[shoulder][0] - normalized[hip][0],
            normalized[shoulder][1] - normalized[hip][1],
        )
        return _vec_angle_to_horizontal(v)

    feats.append(body_line_angle("left"))
    feats.append(body_line_angle("right"))

    # Torso-vs-horizontal: hip_center is the origin post-normalization, so
    # this is just the normalized shoulder_center treated as a vector.
    torso_vec = (
        mirror * (shoulder_center[0] - hip_center[0]) / torso_length,
        (shoulder_center[1] - hip_center[1]) / torso_length,
    )
    feats.append(_vec_angle_to_horizontal(torso_vec))

    assert len(feats) == FEATURE_DIM
    return feats


def extract_frame_features(frame):
    """Convenience wrapper: extract_features() from a raw {"t": ..., "joints": {...}} frame dict."""
    joints = frame.get("joints") if isinstance(frame, dict) else None
    if joints is None:
        return None
    return extract_features(joints)
