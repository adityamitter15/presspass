"""
Shared data loading / splitting helpers used by both train.py and
evaluate.py, so the two never drift apart on how sessions are turned into
feature matrices or how the held-out split is derived.

A "session" is one JSON file written by the iOS app (see the format
documented in README.md and enforced loosely here). Splitting is done by
session, not by frame, so frames from the same recording never leak
across the train/test boundary.
"""

import json
from pathlib import Path

import numpy as np
from sklearn.model_selection import train_test_split

from features import extract_features, FEATURE_DIM

VALID_LABELS = ("up", "down", "not_pushup")


class Session:
    __slots__ = ("session_id", "label", "source", "path", "frames")

    def __init__(self, session_id, label, source, path, frames):
        self.session_id = session_id
        self.label = label
        self.source = source
        self.path = path
        self.frames = frames


def load_sessions(data_dir):
    """
    Read every *.json file in `data_dir` and return a list of Session
    objects. Files that are missing required fields or have an
    unrecognized label are skipped with a warning printed to stdout
    (this keeps a single malformed recording from killing a whole
    training run).
    """
    data_dir = Path(data_dir)
    sessions = []
    for path in sorted(data_dir.glob("*.json")):
        try:
            with open(path, "r") as f:
                doc = json.load(f)
        except (json.JSONDecodeError, OSError) as e:
            print(f"  [skip] {path.name}: could not read/parse ({e})")
            continue

        label = doc.get("label")
        frames = doc.get("frames")
        if label not in VALID_LABELS:
            print(f"  [skip] {path.name}: unknown or missing label {label!r}")
            continue
        if not isinstance(frames, list) or len(frames) == 0:
            print(f"  [skip] {path.name}: no frames")
            continue

        sessions.append(
            Session(
                session_id=path.stem,
                label=label,
                source=doc.get("source", ""),
                path=str(path),
                frames=frames,
            )
        )
    return sessions


def build_dataset(data_dir):
    """
    Load all sessions in `data_dir` and extract per-frame features.

    Returns:
        X: (N, FEATURE_DIM) float32 array
        y: (N,) array of label strings
        groups: (N,) array of session_id strings (one per row of X)
        sessions: the list of Session objects that contributed at least
            one usable frame, each with a `.label` for stratification
        stats: dict with per-class frame counts and per-class session
            counts, plus counts of dropped (low-confidence/unusable) frames
    """
    sessions = load_sessions(data_dir)

    X_rows, y_rows, group_rows = [], [], []
    kept_sessions = []
    dropped_frames = 0
    per_class_frames = {label: 0 for label in VALID_LABELS}
    per_class_sessions = {label: 0 for label in VALID_LABELS}

    for session in sessions:
        n_before = len(X_rows)
        for frame in session.frames:
            joints = frame.get("joints", {}) if isinstance(frame, dict) else {}
            vec = extract_features(joints)
            if vec is None:
                dropped_frames += 1
                continue
            X_rows.append(vec)
            y_rows.append(session.label)
            group_rows.append(session.session_id)
        n_added = len(X_rows) - n_before
        if n_added > 0:
            kept_sessions.append(session)
            per_class_frames[session.label] += n_added
            per_class_sessions[session.label] += 1
        else:
            print(f"  [skip] {session.session_id}: no usable frames after feature extraction")

    X = np.asarray(X_rows, dtype=np.float32) if X_rows else np.zeros((0, FEATURE_DIM), dtype=np.float32)
    y = np.asarray(y_rows, dtype=object)
    groups = np.asarray(group_rows, dtype=object)

    stats = {
        "total_sessions_loaded": len(sessions),
        "sessions_with_usable_frames": len(kept_sessions),
        "dropped_frames": dropped_frames,
        "frames_per_class": per_class_frames,
        "sessions_per_class": per_class_sessions,
    }
    return X, y, groups, kept_sessions, stats


def session_split(sessions, test_size=0.2, seed=42):
    """
    Stratified split of sessions (not frames) into train/test session id
    sets, stratified by session label.
    """
    session_ids = [s.session_id for s in sessions]
    labels = [s.label for s in sessions]

    label_counts = {label: labels.count(label) for label in set(labels)}
    if min(label_counts.values()) < 2:
        raise ValueError(
            "Need at least 2 sessions per class to do a stratified split; "
            f"got counts {label_counts}"
        )

    train_ids, test_ids = train_test_split(
        session_ids,
        test_size=test_size,
        random_state=seed,
        stratify=labels,
    )
    return set(train_ids), set(test_ids)


def load_train_test_split(data_dir, test_size=0.2, seed=42):
    """
    High-level convenience used by both train.py and evaluate.py:
    load every session in `data_dir`, extract features, and produce a
    session-stratified train/test split.

    Returns a dict with keys: X_train, y_train, X_test, y_test,
    train_session_ids, test_session_ids, stats.
    """
    X, y, groups, sessions, stats = build_dataset(data_dir)
    if len(sessions) == 0:
        raise ValueError(f"No usable sessions found in {data_dir}")

    train_ids, test_ids = session_split(sessions, test_size=test_size, seed=seed)

    train_mask = np.array([g in train_ids for g in groups])
    test_mask = np.array([g in test_ids for g in groups])

    return {
        "X_train": X[train_mask],
        "y_train": y[train_mask],
        "X_test": X[test_mask],
        "y_test": y[test_mask],
        "train_session_ids": sorted(train_ids),
        "test_session_ids": sorted(test_ids),
        "stats": stats,
    }
