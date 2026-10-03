"""
Evaluate a trained pushup pose classifier on the held-out test split:
prints per-class precision/recall/F1 and saves a confusion matrix PNG.

Usage:
    python evaluate.py --data data/raw --out models/

Re-derives the exact same session-stratified train/test split train.py
used (same seed + test_size, read from models/metadata.json if present so
this can't silently drift out of sync with what was actually trained),
then loads the pickled sklearn model from --out and scores it against the
held-out test frames.
"""

import argparse
import json
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
import pickle
from sklearn.metrics import classification_report, confusion_matrix

from dataset import load_train_test_split, VALID_LABELS


def parse_args():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--data", default="data/raw", help="Directory of session JSON files")
    p.add_argument("--out", default="models", help="Directory with trained model(s) + where to save the plot")
    p.add_argument("--model", choices=["auto", "knn", "mlp"], default="auto", help="Which trained model to evaluate")
    p.add_argument("--test-size", type=float, default=None, help="Overrides metadata.json's test_size if given")
    p.add_argument("--seed", type=int, default=None, help="Overrides metadata.json's seed if given")
    return p.parse_args()


def plot_confusion_matrix(cm, labels, out_path, title):
    fig, ax = plt.subplots(figsize=(5.5, 5))
    im = ax.imshow(cm, cmap="Blues")
    ax.set_xticks(range(len(labels)))
    ax.set_yticks(range(len(labels)))
    ax.set_xticklabels(labels, rotation=45, ha="right")
    ax.set_yticklabels(labels)
    ax.set_xlabel("Predicted label")
    ax.set_ylabel("True label")
    ax.set_title(title)

    max_val = cm.max() if cm.size else 1
    for i in range(cm.shape[0]):
        for j in range(cm.shape[1]):
            value = cm[i, j]
            color = "white" if value > max_val / 2 else "black"
            ax.text(j, i, str(value), ha="center", va="center", color=color)

    fig.colorbar(im, ax=ax, fraction=0.046, pad=0.04)
    fig.tight_layout()
    fig.savefig(out_path, dpi=150)
    plt.close(fig)


def main():
    args = parse_args()
    data_dir = Path(args.data)
    out_dir = Path(args.out)

    metadata_path = out_dir / "metadata.json"
    metadata = None
    if metadata_path.exists():
        with open(metadata_path) as f:
            metadata = json.load(f)

    test_size = args.test_size if args.test_size is not None else (metadata["test_size"] if metadata else 0.2)
    seed = args.seed if args.seed is not None else (metadata["seed"] if metadata else 42)

    model_choice = args.model
    if model_choice == "auto":
        model_choice = metadata["exported_model"] if metadata else "mlp"

    model_path = out_dir / f"{model_choice}_model.pkl"
    if not model_path.exists():
        raise FileNotFoundError(f"{model_path} not found -- run train.py first")

    print(f"Loading {model_choice} model from {model_path}")
    with open(model_path, "rb") as f:
        model = pickle.load(f)

    print(f"Loading sessions from {data_dir} and reproducing the train.py split (test_size={test_size}, seed={seed}) ...")
    split = load_train_test_split(data_dir, test_size=test_size, seed=seed)
    X_test, y_test = split["X_test"], split["y_test"]
    print(f"  test frames: {len(X_test)} ({len(split['test_session_ids'])} sessions)")

    y_pred = model.predict(X_test)

    labels = [l for l in VALID_LABELS if l in set(y_test) | set(y_pred)]
    print("\nClassification report (held-out test split):")
    print(classification_report(y_test, y_pred, labels=labels, zero_division=0))

    cm = confusion_matrix(y_test, y_pred, labels=labels)
    out_dir.mkdir(parents=True, exist_ok=True)
    plot_path = out_dir / "confusion_matrix.png"
    plot_confusion_matrix(cm, labels, plot_path, title=f"Confusion matrix ({model_choice})")
    print(f"Saved {plot_path}")


if __name__ == "__main__":
    main()
