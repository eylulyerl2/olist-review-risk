-- =====================================================================
-- 04_features.sql
-- Creates the "ml" schema and the ml.order_features view: one row per
-- delivered order with model features and the label (is_negative).
-- The Python model reads its training data directly from this view.
-- Run with:
--   docker exec olist-db psql -U olist_user -d olist -f /sql/04_features.sql
-- =====================================================================

\set ON_ERROR_STOP on

CREATE SCHEMA IF NOT EXISTS ml;

DROP VIEW IF EXISTS ml.order_features;

CREATE VIEW ml.order_features AS
WITH
-- Label: most recent review of each order (547 orders have several reviews)
latest_review AS (
    SELECT DISTINCT ON (order_id)
           order_id,
           review_score
    FROM core.order_reviews
    ORDER BY order_id, answered_at DESC NULLS LAST, created_at DESC NULLS LAST
),

-- Basket, product and distance features aggregated per order
items AS (
    SELECT i.order_id,
           COUNT(*)                         AS n_items,
           COUNT(DISTINCT i.product_id)     AS n_products,
           COUNT(DISTINCT i.seller_id)      AS n_sellers,
           SUM(i.price)                     AS total_price,
           SUM(i.freight_value)             AS total_freight,
           AVG(p.weight_g)                  AS avg_weight_g,
           AVG(p.photos_qty)                AS avg_photos_qty,
           AVG(p.description_length)        AS avg_description_length,
           -- Haversine distance between customer and seller zip centroids (km).
           -- NULL when either location is unknown. (LEAST() ignores NULLs in
           -- PostgreSQL, so the NULL case must be handled explicitly.)
           AVG(
               CASE
                   WHEN cz.lat IS NULL OR sz.lat IS NULL THEN NULL
                   ELSE 2 * 6371 * ASIN(LEAST(1.0, SQRT(
                            POWER(SIN(RADIANS(sz.lat - cz.lat) / 2), 2)
                            + COS(RADIANS(cz.lat)) * COS(RADIANS(sz.lat))
                            * POWER(SIN(RADIANS(sz.lng - cz.lng) / 2), 2)
                        )))
               END
           )                                AS avg_distance_km
    FROM core.order_items i
    JOIN core.products  p ON p.product_id  = i.product_id
    JOIN core.sellers   s ON s.seller_id   = i.seller_id
    JOIN core.orders    o ON o.order_id    = i.order_id
    JOIN core.customers c ON c.customer_id = o.customer_id
    LEFT JOIN core.zip_locations cz ON cz.zip_code_prefix = c.zip_code_prefix
    LEFT JOIN core.zip_locations sz ON sz.zip_code_prefix = s.zip_code_prefix
    GROUP BY i.order_id
),

-- Category and seller state of the most expensive item in the order
main_item AS (
    SELECT DISTINCT ON (i.order_id)
           i.order_id,
           COALESCE(cat.category_name_english, 'unknown') AS main_category,
           s.state                                        AS seller_state
    FROM core.order_items i
    JOIN core.products p   ON p.product_id = i.product_id
    JOIN core.sellers  s   ON s.seller_id  = i.seller_id
    LEFT JOIN core.categories cat ON cat.category_name = p.category_name
    ORDER BY i.order_id, i.price DESC, i.order_item_id
),

-- Payment features
payments AS (
    SELECT order_id,
           SUM(payment_value)           AS total_payment,
           MAX(payment_installments)    AS max_installments,
           COUNT(DISTINCT payment_type) AS n_payment_types
    FROM core.order_payments
    GROUP BY order_id
),

main_payment AS (
    SELECT DISTINCT ON (order_id)
           order_id,
           payment_type AS main_payment_type
    FROM core.order_payments
    ORDER BY order_id, payment_value DESC, payment_sequential
),

-- Number of earlier orders by the same real customer (no future leakage)
customer_history AS (
    SELECT o.order_id,
           ROW_NUMBER() OVER (PARTITION BY c.customer_unique_id
                              ORDER BY o.purchased_at, o.order_id) - 1 AS prior_orders
    FROM core.orders o
    JOIN core.customers c ON c.customer_id = o.customer_id
)

SELECT
    o.order_id,
    o.purchased_at,

    -- Delivery features
    ROUND(EXTRACT(EPOCH FROM o.delivered_customer_at - o.purchased_at) / 86400.0, 2)  AS delivery_days,
    ROUND(EXTRACT(EPOCH FROM o.estimated_delivery_at - o.purchased_at) / 86400.0, 2)  AS estimated_days,
    ROUND(EXTRACT(EPOCH FROM o.delivered_customer_at - o.estimated_delivery_at) / 86400.0, 2) AS delay_days,
    (o.delivered_customer_at > o.estimated_delivery_at)::int                          AS is_late,
    ROUND(EXTRACT(EPOCH FROM o.approved_at - o.purchased_at) / 3600.0, 2)             AS approval_hours,
    ROUND(EXTRACT(EPOCH FROM o.delivered_carrier_at - o.purchased_at) / 86400.0, 2)   AS carrier_handoff_days,

    -- Basket features
    it.n_items,
    it.n_products,
    it.n_sellers,
    it.total_price,
    it.total_freight,
    ROUND(it.total_freight / NULLIF(it.total_price + it.total_freight, 0), 4)         AS freight_ratio,

    -- Payment features
    pay.total_payment,
    pay.max_installments,
    pay.n_payment_types,
    COALESCE(mp.main_payment_type, 'unknown')                                         AS main_payment_type,

    -- Product features
    mi.main_category,
    ROUND(it.avg_weight_g::numeric, 1)                                                AS avg_weight_g,
    ROUND(it.avg_photos_qty::numeric, 2)                                              AS avg_photos_qty,
    ROUND(it.avg_description_length::numeric, 1)                                      AS avg_description_length,

    -- Location features
    c.state                                                                           AS customer_state,
    mi.seller_state,
    (c.state = mi.seller_state)::int                                                  AS same_state,
    ROUND(it.avg_distance_km::numeric, 1)                                             AS distance_km,

    -- Time and customer features
    EXTRACT(ISODOW FROM o.purchased_at)::int                                          AS purchase_dow,
    ch.prior_orders,

    -- Label
    lr.review_score,
    CASE
        WHEN lr.review_score IS NULL THEN NULL
        WHEN lr.review_score <= 2   THEN 1
        ELSE 0
    END                                                                               AS is_negative

FROM core.orders o
JOIN core.customers      c   ON c.customer_id = o.customer_id
JOIN items               it  ON it.order_id   = o.order_id
JOIN main_item           mi  ON mi.order_id   = o.order_id
JOIN customer_history    ch  ON ch.order_id   = o.order_id
LEFT JOIN payments       pay ON pay.order_id  = o.order_id
LEFT JOIN main_payment   mp  ON mp.order_id   = o.order_id
LEFT JOIN latest_review  lr  ON lr.order_id   = o.order_id
WHERE o.order_status = 'delivered'
  AND o.delivered_customer_at IS NOT NULL
  AND o.estimated_delivery_at IS NOT NULL;

COMMENT ON VIEW ml.order_features IS
    'One row per delivered order: model features + label is_negative (latest review score <= 2; NULL if not reviewed).';

-- ---------------------------------------------------------------------
-- Verification
-- ---------------------------------------------------------------------

SELECT COUNT(*)                                          AS total_orders,
       COUNT(is_negative)                                AS labeled_orders,
       COUNT(*) - COUNT(is_negative)                     AS unlabeled_orders,
       ROUND(100.0 * AVG(is_negative), 2)                AS negative_pct,
       COUNT(*) FILTER (WHERE distance_km IS NULL)       AS missing_distance,
       COUNT(*) FILTER (WHERE distance_km > 5000)        AS implausible_distance,
       MAX(distance_km)                                  AS max_distance_km
FROM ml.order_features;

-- First insight: does late delivery affect negative reviews?
SELECT is_late,
       COUNT(*)                           AS orders,
       ROUND(100.0 * AVG(is_negative), 2) AS negative_pct
FROM ml.order_features
WHERE is_negative IS NOT NULL
GROUP BY is_late
ORDER BY is_late;