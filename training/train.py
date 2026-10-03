"""
Train the pushup pose classifier and export the winner to Core ML.

Usage:
    python train.py --data data/raw --out models/

Loads every session JSON under --data, extracts a 25-dim feature vector
per frame (features.py), splits sessions (not frames) 80/20 into
train/test so a single recording never leaks across the split, trains a
k-NN and a small MLP, reports both accuracies, and exports the better one
to models/PushupPoseClassifier.mlmodel via coremltools. If the winner is
k-NN and it can't be exported cleanly, the MLP is exported instead (see
coreml_export.py for why).

Also writes models/metadata.json (train date, per-class counts, test
accuracy, feature version) and pickles both trained sklearn models
(models/knn_model.pkl, models/mlp_model.pkl) so evaluate.py can reuse them
without retraining.
"""

import argparse
import json
import pickle
import sys
from datetime import datetime, timezone
from pathlib import Path

import numpy as np
from sklearn.metrics import accuracy_score
from sklearn.neighbors import KNeighborsClassifier
from sklearn.neural_network import MLPClassifier

from dataset import load_train_test_split
from features import FEATURE_DIM, FEATURE_NAMES, FEATURE_VERSION
import coreml_export

MODEL_FILENAME = "PushupPoseClassifier.mlmodel"


def parse_args():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--data", default="data/raw", help="Directory of session JSON files")
    p.add_argument("--out", default="models", help="Directory to write the model + metadata into")
    p.add_argument("--test-size", type=float, default=0.2, help="Fraction of sessions held out for test")
    p.add_argument("--seed", type=int, default=42)
    p.add_argument("--knn-k", type=int, default=10)
    p.add_argument("--hidden-size", type=int, default=32)
    p.add_argument("--mlp-max-iter", type=int, default=3000)
    return p.parse_args()


def main():
    args = parse_args()
    data_dir = Path(args.data)
    out_dir = Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)

    print(f"Loading sessions from {data_dir} ...")
    split = load_train_test_split(data_dir, test_size=args.test_size, seed=args.seed)
    stats = split["stats"]
    X_train, y_train = split["X_train"], split["y_train"]
    X_test, y_test = split["X_test"], split["y_test"]

    print(f"  sessions loaded: {stats['total_sessions_loaded']}, usable: {stats['sessions_with_usable_frames']}")
    print(f"  frames per class: {stats['frames_per_class']}")
    print(f"  sessions per class: {stats['sessions_per_class']}")
    print(f"  dropped (low-confidence/unusable) frames: {stats['dropped_frames']}")
    print(f"  train frames: {len(X_train)} ({len(split['train_session_ids'])} sessions)")
    print(f"  test frames:  {len(X_test)} ({len(split['test_session_ids'])} sessions)")

    if len(X_train) == 0 or len(X_test) == 0:
        print("Not enough data to train/evaluate. Record more sessions or run make_synthetic.py first.")
        sys.exit(1)

    # --- k-NN ---
    print(f"\nTraining k-NN (k={args.knn_k}, distance-weighted) ...")
    knn = KNeighborsClassifier(n_neighbors=args.knn_k, weights="distance")
    knn.fit(X_train, y_train)
    knn_pred = knn.predict(X_test)
    knn_acc = accuracy_score(y_test, knn_pred)
    print(f"  k-NN test accuracy: {knn_acc:.4f}")

    # --- MLP ---
    print(f"\nTraining MLP (hidden_layer_sizes=({args.hidden_size},)) ...")
    mlp = MLPClassifier(
        hidden_layer_sizes=(args.hidden_size,),
        activation="relu",
        max_iter=args.mlp_max_iter,
        random_state=args.seed,
        early_stopping=True,
        n_iter_no_change=25,
    )
    mlp.fit(X_train, y_train)
    mlp_pred = mlp.predict(X_test)
    mlp_acc = accuracy_score(y_test, mlp_pred)
    print(f"  MLP test accuracy: {mlp_acc:.4f}")

    winner_name = "knn" if knn_acc > mlp_acc else "mlp"
    print(f"\nWinner by test accuracy: {winner_name} (knn={knn_acc:.4f}, mlp={mlp_acc:.4f})")

    # --- Core ML export ---
    fallback_note = None
    exported_name = winner_name
    description = "Pushup pose classifier (up / down / not_pushup) trained on 25-dim frame features."

    try:
        if winner_name == "knn":
            mlmodel = coreml_export.export_knn_to_coreml(knn, FEATURE_NAMES, description)
        else:
            mlmodel = coreml_export.export_mlp_to_coreml(mlp, FEATURE_NAMES, description)
        print(f"Exported {winner_name} to Core ML cleanly.")
    except Exception as e:
        print(f"  [warn] Could not cleanly export {winner_name} to Core ML: {e}")
        if winner_name != "mlp":
            print("  Falling back to exporting the MLP instead.")
            fallback_note = f"{winner_name} export failed ({e}); exported MLP instead."
            exported_name = "mlp"
            mlmodel = coreml_export.export_mlp_to_coreml(mlp, FEATURE_NAMES, description)
        else:
            raise

    model_path = out_dir / MODEL_FILENAME
    mlmodel.save(str(model_path))
    print(f"Saved {model_path}")

    # Reload to confirm it's a valid, loadable .mlmodel file.
    import coremltools

    reloaded = coremltools.models.MLModel(str(model_path))
    print(f"Verified {model_path} reloads via coremltools ({reloaded.get_spec().description.output})")

    # Persist both trained sklearn models so evaluate.py doesn't need to retrain.
    with open(out_dir / "knn_model.pkl", "wb") as f:
        pickle.dump(knn, f)
    with open(out_dir / "mlp_model.pkl", "wb") as f:
        pickle.dump(mlp, f)

    metadata = {
        "train_date": datetime.now(timezone.utc).isoformat(),
        "feature_version": FEATURE_VERSION,
        "feature_dim": FEATURE_DIM,
        "feature_names": list(FEATURE_NAMES),
        "data_dir": str(data_dir),
        "test_size": args.test_size,
        "seed": args.seed,
        "sessions_per_class": stats["sessions_per_class"],
        "frames_per_class": stats["frames_per_class"],
        "dropped_frames": stats["dropped_frames"],
        "train_frame_count": int(len(X_train)),
        "test_frame_count": int(len(X_test)),
        "knn": {"k": args.knn_k, "weights": "distance", "test_accuracy": float(knn_acc)},
        "mlp": {
            "hidden_layer_sizes": [args.hidden_size],
            "test_accuracy": float(mlp_acc),
        },
        "winner_by_accuracy": winner_name,
        "exported_model": exported_name,
        "exported_model_file": MODEL_FILENAME,
        "export_fallback_note": fallback_note,
    }
    with open(out_dir / "metadata.json", "w") as f:
        json.dump(metadata, f, indent=2)
    print(f"Saved {out_dir / 'metadata.json'}")


if __name__ == "__main__":
    main()
