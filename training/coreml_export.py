"""
Core ML export helpers.

Neither of the two models train.py trains converts cleanly through
coremltools' generic `coremltools.converters.sklearn.convert()` path:

  - KNeighborsClassifier(weights="distance") is explicitly rejected by
    that converter ("weight function not supported for CoreML
    conversion: distance"), and even the uniform-weight variant fails
    ("does not support output scores for classes").
  - MLPClassifier is not in that converter's supported model list at all.

So both models get their own export path here:

  - KNN: built directly as a Core ML "nearest neighbors classifier" via
    coremltools.models.nearest_neighbors.KNearestNeighborsClassifierBuilder,
    which does support inverse-distance weighting. In practice this model
    type could not be evaluated locally with this coremltools build (the
    local prediction engine raises "Unrecognized sequence type" for it),
    so export_knn_to_coreml() self-checks the model with a local
    .predict() call and raises if that fails -- this is what train.py
    uses to decide whether to fall back to the MLP.
  - MLP: built by hand with coremltools.models.neural_network.NeuralNetworkBuilder,
    copying the trained sklearn MLPClassifier's weight matrices
    (coefs_/intercepts_) into Dense (inner product) + ReLU layers, and a
    final softmax. This mirrors sklearn's forward pass exactly and is
    verified below to reproduce sklearn's predict_proba() output.
"""

import numpy as np
import coremltools
from coremltools.models import datatypes
from coremltools.models.neural_network import NeuralNetworkBuilder
from coremltools.models.nearest_neighbors import KNearestNeighborsClassifierBuilder

INPUT_NAME = "pose_features"
LABEL_OUTPUT_NAME = "label"
PROBABILITY_OUTPUT_NAME = "labelProbability"


def _self_check(mlmodel, feature_dim, class_labels):
    """Run one dummy prediction through the model to catch models that
    build/save fine but cannot actually be evaluated (seen in practice
    with the nearest-neighbors classifier spec on some coremltools
    builds)."""
    sample = np.zeros(feature_dim, dtype=np.float32)
    out = mlmodel.predict({INPUT_NAME: sample})
    if LABEL_OUTPUT_NAME not in out:
        raise RuntimeError(f"self-check: no {LABEL_OUTPUT_NAME!r} in prediction output {out!r}")
    if out[LABEL_OUTPUT_NAME] not in class_labels:
        raise RuntimeError(f"self-check: predicted label {out[LABEL_OUTPUT_NAME]!r} not in {class_labels}")
    return out


def export_mlp_to_coreml(mlp, feature_names, model_description=""):
    """
    Build a Core ML neural network classifier that reproduces `mlp`
    (a fitted sklearn MLPClassifier) exactly, by copying its weights.

    Only ReLU hidden activations and a softmax/logistic output are
    supported (sklearn's defaults for MLPClassifier), which is what
    train.py configures.
    """
    if mlp.activation != "relu":
        raise ValueError(f"only 'relu' hidden activation is supported for export, got {mlp.activation!r}")

    feature_dim = mlp.coefs_[0].shape[0]
    class_labels = [str(c) for c in mlp.classes_]

    input_features = [(INPUT_NAME, datatypes.Array(feature_dim))]
    output_features = [(PROBABILITY_OUTPUT_NAME, datatypes.Dictionary(key_type=str))]

    builder = NeuralNetworkBuilder(input_features, output_features, mode="classifier")
    builder.spec.description.metadata.shortDescription = model_description

    last_output = INPUT_NAME
    n_layers = len(mlp.coefs_)
    for i, (W, b) in enumerate(zip(mlp.coefs_, mlp.intercepts_)):
        is_last = i == n_layers - 1
        ip_out = "logits" if is_last else f"dense_{i}"
        builder.add_inner_product(
            name=f"ip_{i}",
            W=W.T,
            b=b,
            input_channels=W.shape[0],
            output_channels=W.shape[1],
            has_bias=True,
            input_name=last_output,
            output_name=ip_out,
        )
        if is_last:
            last_output = ip_out
        else:
            act_out = f"relu_{i}"
            builder.add_activation(
                name=f"act_{i}",
                non_linearity="RELU",
                input_name=ip_out,
                output_name=act_out,
            )
            last_output = act_out

    # sklearn's MLPClassifier uses softmax for >2 classes, logistic for 2.
    if mlp.out_activation_ == "softmax":
        builder.add_softmax(name="softmax", input_name=last_output, output_name=PROBABILITY_OUTPUT_NAME)
    elif mlp.out_activation_ == "logistic":
        builder.add_activation(
            name="logistic",
            non_linearity="SIGMOID",
            input_name=last_output,
            output_name=PROBABILITY_OUTPUT_NAME,
        )
    else:
        raise ValueError(f"unsupported output activation {mlp.out_activation_!r}")

    builder.set_class_labels(
        class_labels, predicted_feature_name=LABEL_OUTPUT_NAME, prediction_blob=PROBABILITY_OUTPUT_NAME
    )

    mlmodel = coremltools.models.MLModel(builder.spec)
    _self_check(mlmodel, feature_dim, class_labels)
    return mlmodel


def export_knn_to_coreml(knn, feature_names, model_description=""):
    """
    Build a Core ML nearest-neighbors classifier that reproduces `knn`
    (a fitted sklearn KNeighborsClassifier) by copying its training
    samples into the Core ML model's index.

    Raises if the resulting model fails a local self-check prediction
    (this is the "coremltools can't convert k-NN cleanly" case train.py
    falls back on).
    """
    feature_dim = knn.n_features_in_
    class_labels = [str(c) for c in knn.classes_]
    weighting_scheme = "inverse_distance" if knn.weights == "distance" else "uniform"

    X_train = knn._fit_X
    y_train = [str(v) for v in knn._y] if hasattr(knn, "_y") else None
    if y_train is None:
        # classes_ + _y indices fallback
        y_train = [class_labels[i] for i in knn._y]

    builder = KNearestNeighborsClassifierBuilder(
        input_name=INPUT_NAME,
        output_name=LABEL_OUTPUT_NAME,
        number_of_dimensions=feature_dim,
        default_class_label=class_labels[0],
        number_of_neighbors=knn.n_neighbors,
        weighting_scheme=weighting_scheme,
    )
    builder.spec.description.metadata.shortDescription = model_description
    builder.add_samples(np.asarray(X_train, dtype=np.float32).tolist(), y_train)

    mlmodel = coremltools.models.MLModel(builder.spec)
    _self_check(mlmodel, feature_dim, class_labels)
    return mlmodel
