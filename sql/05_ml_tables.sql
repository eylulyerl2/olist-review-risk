-- =====================================================================
-- 05_ml_tables.sql
-- Tables where the Python model writes its results back to the database:
--   ml.model_runs     one row per trained model
--   ml.model_metrics  evaluation metrics per model and data split
--   ml.predictions    risk score per order (filled by src/predict.py)
-- Run with:
--   docker exec olist-db psql -U olist_user -d olist -f /sql/05_ml_tables.sql
-- =====================================================================

\set ON_ERROR_STOP on

CREATE SCHEMA IF NOT EXISTS ml;

DROP TABLE IF EXISTS ml.predictions;
DROP TABLE IF EXISTS ml.model_metrics;
DROP TABLE IF EXISTS ml.model_runs;

CREATE TABLE ml.model_runs (
    run_id         SERIAL PRIMARY KEY,
    trained_at     TIMESTAMP     NOT NULL DEFAULT now(),
    model_name     TEXT          NOT NULL,
    is_selected    BOOLEAN       NOT NULL DEFAULT FALSE,
    threshold      NUMERIC(4,2)  NOT NULL CHECK (threshold BETWEEN 0 AND 1),
    train_rows     INTEGER       NOT NULL CHECK (train_rows > 0),
    train_seconds  NUMERIC(10,2) NOT NULL,
    params         JSONB
);

-- At most one model can be marked as the selected (production) model.
CREATE UNIQUE INDEX uq_model_runs_one_selected
    ON ml.model_runs (is_selected)
    WHERE is_selected;

CREATE TABLE ml.model_metrics (
    run_id           INTEGER      NOT NULL REFERENCES ml.model_runs (run_id) ON DELETE CASCADE,
    split            TEXT         NOT NULL CHECK (split IN ('validation', 'test')),
    n_rows           INTEGER      NOT NULL,
    accuracy         NUMERIC(6,4) NOT NULL,
    precision_score  NUMERIC(6,4) NOT NULL,
    recall_score     NUMERIC(6,4) NOT NULL,
    f1_score         NUMERIC(6,4) NOT NULL,
    roc_auc          NUMERIC(6,4) NOT NULL,
    tn               INTEGER      NOT NULL,
    fp               INTEGER      NOT NULL,
    fn               INTEGER      NOT NULL,
    tp               INTEGER      NOT NULL,
    PRIMARY KEY (run_id, split)
);

CREATE TABLE ml.predictions (
    order_id            VARCHAR(32)  NOT NULL REFERENCES core.orders (order_id),
    run_id              INTEGER      NOT NULL REFERENCES ml.model_runs (run_id) ON DELETE CASCADE,
    risk_score          NUMERIC(6,4) NOT NULL CHECK (risk_score BETWEEN 0 AND 1),
    predicted_negative  BOOLEAN      NOT NULL,
    predicted_at        TIMESTAMP    NOT NULL DEFAULT now(),
    PRIMARY KEY (order_id, run_id)
);

-- Supports "highest-risk orders of a model run" queries in the dashboard.
CREATE INDEX idx_predictions_run_risk
    ON ml.predictions (run_id, risk_score DESC);

COMMENT ON TABLE ml.model_runs    IS 'One row per trained model; is_selected marks the model used for predictions.';
COMMENT ON TABLE ml.model_metrics IS 'Evaluation metrics and confusion matrix per model run and data split.';
COMMENT ON TABLE ml.predictions   IS 'Negative-review risk score per order, written back by the Python model.';