"""Train and evaluate classifiers that predict negative reviews.

Data flow:
    PostgreSQL (ml.order_features)
        -> pandas DataFrame
        -> scikit-learn pipelines (preprocessing + model)
        -> metrics written back to PostgreSQL (ml.model_runs, ml.model_metrics)
        -> selected model saved to models/review_risk_model.joblib
"""

import json
import time

import joblib
import numpy as np
import pandas as pd
from sklearn.compose import ColumnTransformer
from sklearn.dummy import DummyClassifier
from sklearn.ensemble import RandomForestClassifier
from sklearn.impute import SimpleImputer
from sklearn.linear_model import LogisticRegression
from sklearn.metrics import (
    accuracy_score,
    confusion_matrix,
    f1_score,
    precision_score,
    recall_score,
    roc_auc_score,
)
from sklearn.neighbors import KNeighborsClassifier
from sklearn.pipeline import Pipeline
from sklearn.preprocessing import OneHotEncoder, StandardScaler
from sqlalchemy import text

from db import PROJECT_ROOT, get_engine

NUMERIC_FEATURES = [
    "delivery_days", "estimated_days", "delay_days", "is_late",
    "approval_hours", "carrier_handoff_days",
    "n_items", "n_products", "n_sellers",
    "total_price", "total_freight", "freight_ratio",
    "total_payment", "max_installments", "n_payment_types",
    "avg_weight_g", "avg_photos_qty", "avg_description_length",
    "same_state", "distance_km", "purchase_dow", "prior_orders",
]
CATEGORICAL_FEATURES = [
    "main_payment_type", "main_category", "customer_state", "seller_state",
]
FEATURES = NUMERIC_FEATURES + CATEGORICAL_FEATURES
LABEL = "is_negative"

MODEL_PATH = PROJECT_ROOT / "models" / "review_risk_model.joblib"
RANDOM_STATE = 42
BASELINE_NAME = "baseline_majority"


# ---------------------------------------------------------------------------
# Data
# ---------------------------------------------------------------------------

def load_data(engine) -> pd.DataFrame:
    """Read labeled orders directly from the feature view, ordered by time."""
    columns = ", ".join(["order_id", "purchased_at", *FEATURES, LABEL])
    query = (
        f"SELECT {columns} FROM ml.order_features "
        f"WHERE {LABEL} IS NOT NULL "
        f"ORDER BY purchased_at, order_id"
    )
    df = pd.read_sql(query, engine)

    # PostgreSQL NUMERIC values arrive as Python Decimal objects -> convert to float.
    df[NUMERIC_FEATURES] = df[NUMERIC_FEATURES].astype(float)
    df[LABEL] = df[LABEL].astype(int)
    return df


def time_split(df: pd.DataFrame):
    """Chronological 70 / 15 / 15 split: train on the past, test on the future."""
    n = len(df)
    train_end, val_end = int(n * 0.70), int(n * 0.85)
    return df.iloc[:train_end], df.iloc[train_end:val_end], df.iloc[val_end:]


# ---------------------------------------------------------------------------
# Models
# ---------------------------------------------------------------------------

def build_preprocessor() -> ColumnTransformer:
    numeric = Pipeline([
        ("impute", SimpleImputer(strategy="median")),
        ("scale", StandardScaler()),
    ])
    categorical = Pipeline([
        ("impute", SimpleImputer(strategy="most_frequent")),
        ("onehot", OneHotEncoder(handle_unknown="ignore")),
    ])
    return ColumnTransformer([
        ("num", numeric, NUMERIC_FEATURES),
        ("cat", categorical, CATEGORICAL_FEATURES),
    ])


def build_models() -> dict:
    return {
        BASELINE_NAME: DummyClassifier(strategy="most_frequent"),
        "logistic_regression": LogisticRegression(
            max_iter=2000, class_weight="balanced", random_state=RANDOM_STATE
        ),
        "knn": KNeighborsClassifier(n_neighbors=25, weights="distance", n_jobs=-1),
        "random_forest": RandomForestClassifier(
            n_estimators=300,
            min_samples_leaf=5,
            class_weight="balanced_subsample",
            n_jobs=-1,
            random_state=RANDOM_STATE,
        ),
    }


# ---------------------------------------------------------------------------
# Evaluation
# ---------------------------------------------------------------------------

def best_threshold(y_true, scores) -> float:
    """Decision threshold that maximizes F1 (chosen on the validation set only)."""
    thresholds = np.round(np.arange(0.05, 0.96, 0.01), 2)
    f1s = [f1_score(y_true, scores >= t, zero_division=0) for t in thresholds]
    return float(thresholds[int(np.argmax(f1s))])


def evaluate(y_true, scores, threshold: float) -> dict:
    y_pred = (scores >= threshold).astype(int)
    tn, fp, fn, tp = confusion_matrix(y_true, y_pred, labels=[0, 1]).ravel()
    return {
        "n_rows": int(len(y_true)),
        "accuracy": float(accuracy_score(y_true, y_pred)),
        "precision_score": float(precision_score(y_true, y_pred, zero_division=0)),
        "recall_score": float(recall_score(y_true, y_pred, zero_division=0)),
        "f1_score": float(f1_score(y_true, y_pred, zero_division=0)),
        "roc_auc": float(roc_auc_score(y_true, scores)),
        "tn": int(tn), "fp": int(fp), "fn": int(fn), "tp": int(tp),
    }


# ---------------------------------------------------------------------------
# Write-back to the database
# ---------------------------------------------------------------------------

def save_runs_to_db(engine, results: list, selected_name: str, train_rows: int) -> dict:
    """Insert one ml.model_runs row per model and its metrics, in one transaction."""
    run_ids = {}
    with engine.begin() as conn:
        conn.execute(text("UPDATE ml.model_runs SET is_selected = FALSE WHERE is_selected"))
        for r in results:
            run_id = conn.execute(
                text("""
                    INSERT INTO ml.model_runs
                        (model_name, is_selected, threshold, train_rows, train_seconds, params)
                    VALUES
                        (:model_name, :is_selected, :threshold, :train_rows, :train_seconds,
                         CAST(:params AS JSONB))
                    RETURNING run_id
                """),
                {
                    "model_name": r["name"],
                    "is_selected": r["name"] == selected_name,
                    "threshold": r["threshold"],
                    "train_rows": train_rows,
                    "train_seconds": round(r["train_seconds"], 2),
                    "params": json.dumps(
                        r["pipeline"].named_steps["model"].get_params(), default=str
                    ),
                },
            ).scalar_one()

            for split, metrics in (("validation", r["val"]), ("test", r["test"])):
                conn.execute(
                    text("""
                        INSERT INTO ml.model_metrics
                            (run_id, split, n_rows, accuracy, precision_score, recall_score,
                             f1_score, roc_auc, tn, fp, fn, tp)
                        VALUES
                            (:run_id, :split, :n_rows, :accuracy, :precision_score, :recall_score,
                             :f1_score, :roc_auc, :tn, :fp, :fn, :tp)
                    """),
                    {"run_id": run_id, "split": split, **metrics},
                )
            run_ids[r["name"]] = run_id
    return run_ids


# ---------------------------------------------------------------------------
# Reporting helpers
# ---------------------------------------------------------------------------

def print_top_features(pipeline: Pipeline, top_n: int = 10) -> None:
    model = pipeline.named_steps["model"]
    names = pipeline.named_steps["preprocess"].get_feature_names_out()
    if hasattr(model, "feature_importances_"):
        values, label = model.feature_importances_, "importance"
    elif hasattr(model, "coef_"):
        values, label = np.abs(model.coef_[0]), "|coefficient|"
    else:
        return
    top = (
        pd.DataFrame({"feature": names, label: values})
        .sort_values(label, ascending=False)
        .head(top_n)
    )
    print(f"\nTop {top_n} features of the selected model:")
    print(top.to_string(index=False))


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> None:
    engine = get_engine()

    print("Loading data from ml.order_features ...")
    df = load_data(engine)
    train, val, test = time_split(df)
    for name, part in (("train", train), ("validation", val), ("test", test)):
        print(
            f"  {name:<10} {len(part):>6} rows  "
            f"{part['purchased_at'].min():%Y-%m-%d} -> {part['purchased_at'].max():%Y-%m-%d}  "
            f"negative rate {part[LABEL].mean():.2%}"
        )

    X_train, y_train = train[FEATURES], train[LABEL].to_numpy()
    X_val, y_val = val[FEATURES], val[LABEL].to_numpy()
    X_test, y_test = test[FEATURES], test[LABEL].to_numpy()

    results = []
    for name, estimator in build_models().items():
        print(f"\nTraining {name} ...")
        pipeline = Pipeline([("preprocess", build_preprocessor()), ("model", estimator)])

        start = time.perf_counter()
        pipeline.fit(X_train, y_train)
        train_seconds = time.perf_counter() - start

        val_scores = pipeline.predict_proba(X_val)[:, 1]
        threshold = 0.5 if name == BASELINE_NAME else best_threshold(y_val, val_scores)
        test_scores = pipeline.predict_proba(X_test)[:, 1]

        result = {
            "name": name,
            "pipeline": pipeline,
            "threshold": threshold,
            "train_seconds": train_seconds,
            "val": evaluate(y_val, val_scores, threshold),
            "test": evaluate(y_test, test_scores, threshold),
        }
        results.append(result)
        print(
            f"  done in {train_seconds:.1f}s | threshold {threshold:.2f} | "
            f"validation F1 {result['val']['f1_score']:.4f}"
        )

    # Model selection uses the validation set only; the test set is reported once.
    candidates = [r for r in results if r["name"] != BASELINE_NAME]
    best = max(candidates, key=lambda r: r["val"]["f1_score"])

    summary = pd.DataFrame([
        {
            "model": r["name"],
            "threshold": r["threshold"],
            "val_f1": r["val"]["f1_score"],
            "test_accuracy": r["test"]["accuracy"],
            "test_precision": r["test"]["precision_score"],
            "test_recall": r["test"]["recall_score"],
            "test_f1": r["test"]["f1_score"],
            "test_roc_auc": r["test"]["roc_auc"],
            "train_s": r["train_seconds"],
        }
        for r in results
    ]).round(4)
    print("\nResults (test set = the most recent 15% of orders):")
    print(summary.to_string(index=False))

    t = best["test"]
    print(f"\nSelected model: {best['name']} (highest validation F1)")
    print("Confusion matrix on the test set:")
    print(f"                 predicted 0   predicted 1")
    print(f"  actual 0       {t['tn']:>11}   {t['fp']:>11}")
    print(f"  actual 1       {t['fn']:>11}   {t['tp']:>11}")

    print_top_features(best["pipeline"])

    run_ids = save_runs_to_db(engine, results, best["name"], len(train))
    print(f"\nSaved {len(run_ids)} model runs to ml.model_runs / ml.model_metrics: {run_ids}")

    MODEL_PATH.parent.mkdir(exist_ok=True)
    joblib.dump(
        {
            "pipeline": best["pipeline"],
            "threshold": best["threshold"],
            "run_id": run_ids[best["name"]],
            "model_name": best["name"],
            "features": FEATURES,
        },
        MODEL_PATH,
    )
    print(f"Selected model saved to {MODEL_PATH.relative_to(PROJECT_ROOT)}")


if __name__ == "__main__":
    main()