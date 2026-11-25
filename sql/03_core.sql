-- =====================================================================
-- 03_core.sql
-- Builds the normalized, typed and constrained "core" schema from the
-- staging layer: primary keys, foreign keys, CHECK constraints, indexes.
-- Design decisions are based on the checks in 02_profile_staging.sql.
-- Run with:
--   docker exec olist-db psql -U olist_user -d olist -f /sql/03_core.sql
-- =====================================================================

\set ON_ERROR_STOP on

BEGIN;

DROP SCHEMA IF EXISTS core CASCADE;
CREATE SCHEMA core;

-- ---------------------------------------------------------------------
-- 1. Table definitions
-- ---------------------------------------------------------------------

CREATE TABLE core.categories (
    category_name          TEXT PRIMARY KEY,
    category_name_english  TEXT NOT NULL
);

CREATE TABLE core.products (
    product_id          VARCHAR(32) PRIMARY KEY,
    category_name       TEXT REFERENCES core.categories (category_name),
    name_length         INTEGER,
    description_length  INTEGER,
    photos_qty          INTEGER,
    weight_g            INTEGER,
    length_cm           INTEGER,
    height_cm           INTEGER,
    width_cm            INTEGER
);

CREATE TABLE core.zip_locations (
    zip_code_prefix  VARCHAR(5) PRIMARY KEY,
    lat              DOUBLE PRECISION NOT NULL,
    lng              DOUBLE PRECISION NOT NULL,
    city             TEXT,
    state            CHAR(2)
);

CREATE TABLE core.customers (
    customer_id         VARCHAR(32) PRIMARY KEY,
    customer_unique_id  VARCHAR(32) NOT NULL,
    zip_code_prefix     VARCHAR(5),
    city                TEXT,
    state               CHAR(2)
);

CREATE TABLE core.sellers (
    seller_id        VARCHAR(32) PRIMARY KEY,
    zip_code_prefix  VARCHAR(5),
    city             TEXT,
    state            CHAR(2)
);

CREATE TABLE core.orders (
    order_id               VARCHAR(32) PRIMARY KEY,
    customer_id            VARCHAR(32) NOT NULL REFERENCES core.customers (customer_id),
    order_status           TEXT NOT NULL,
    purchased_at           TIMESTAMP NOT NULL,
    approved_at            TIMESTAMP,
    delivered_carrier_at   TIMESTAMP,
    delivered_customer_at  TIMESTAMP,
    estimated_delivery_at  TIMESTAMP
);

CREATE TABLE core.order_items (
    order_id           VARCHAR(32) NOT NULL REFERENCES core.orders (order_id),
    order_item_id      SMALLINT    NOT NULL,
    product_id         VARCHAR(32) NOT NULL REFERENCES core.products (product_id),
    seller_id          VARCHAR(32) NOT NULL REFERENCES core.sellers (seller_id),
    shipping_limit_at  TIMESTAMP,
    price              NUMERIC(10,2) NOT NULL CHECK (price >= 0),
    freight_value      NUMERIC(10,2) NOT NULL CHECK (freight_value >= 0),
    PRIMARY KEY (order_id, order_item_id)
);

CREATE TABLE core.order_payments (
    order_id              VARCHAR(32) NOT NULL REFERENCES core.orders (order_id),
    payment_sequential    SMALLINT    NOT NULL,
    payment_type          TEXT        NOT NULL,
    payment_installments  SMALLINT,
    payment_value         NUMERIC(10,2) NOT NULL CHECK (payment_value >= 0),
    PRIMARY KEY (order_id, payment_sequential)
);

CREATE TABLE core.order_reviews (
    review_id        VARCHAR(32) NOT NULL,
    order_id         VARCHAR(32) NOT NULL REFERENCES core.orders (order_id),
    review_score     SMALLINT    NOT NULL CHECK (review_score BETWEEN 1 AND 5),
    comment_title    TEXT,
    comment_message  TEXT,
    created_at       TIMESTAMP,
    answered_at      TIMESTAMP,
    PRIMARY KEY (review_id, order_id)
);

-- ---------------------------------------------------------------------
-- 2. Data transformation: staging (TEXT) -> core (typed)
--    NULLIF(x, '') turns empty strings into proper NULLs.
-- ---------------------------------------------------------------------

-- Categories: every category used by products, plus every translated one.
-- If no English translation exists, the original name is used.
INSERT INTO core.categories (category_name, category_name_english)
SELECT c.category_name,
       COALESCE(NULLIF(t.product_category_name_english, ''), c.category_name)
FROM (
    SELECT product_category_name AS category_name
    FROM staging.products
    WHERE COALESCE(product_category_name, '') <> ''
    UNION
    SELECT product_category_name
    FROM staging.category_translation
    WHERE COALESCE(product_category_name, '') <> ''
) c
LEFT JOIN staging.category_translation t
       ON t.product_category_name = c.category_name;

INSERT INTO core.products
SELECT product_id,
       NULLIF(product_category_name, ''),
       NULLIF(product_name_lenght, '')::numeric::int,
       NULLIF(product_description_lenght, '')::numeric::int,
       NULLIF(product_photos_qty, '')::numeric::int,
       NULLIF(product_weight_g, '')::numeric::int,
       NULLIF(product_length_cm, '')::numeric::int,
       NULLIF(product_height_cm, '')::numeric::int,
       NULLIF(product_width_cm, '')::numeric::int
FROM staging.products;

-- One row per zip prefix: mean coordinates of the points that fall inside
-- Brazil's bounding box (the raw data contains some invalid coordinates).
INSERT INTO core.zip_locations
SELECT geolocation_zip_code_prefix,
       AVG(geolocation_lat::double precision),
       AVG(geolocation_lng::double precision),
       MODE() WITHIN GROUP (ORDER BY geolocation_city),
       MODE() WITHIN GROUP (ORDER BY geolocation_state)
FROM staging.geolocation
WHERE geolocation_lat::double precision BETWEEN -34.0 AND 5.5
  AND geolocation_lng::double precision BETWEEN -74.0 AND -34.0
GROUP BY geolocation_zip_code_prefix;

INSERT INTO core.customers
SELECT customer_id,
       customer_unique_id,
       NULLIF(customer_zip_code_prefix, ''),
       NULLIF(customer_city, ''),
       NULLIF(customer_state, '')
FROM staging.customers;

INSERT INTO core.sellers
SELECT seller_id,
       NULLIF(seller_zip_code_prefix, ''),
       NULLIF(seller_city, ''),
       NULLIF(seller_state, '')
FROM staging.sellers;

INSERT INTO core.orders
SELECT order_id,
       customer_id,
       order_status,
       order_purchase_timestamp::timestamp,
       NULLIF(order_approved_at, '')::timestamp,
       NULLIF(order_delivered_carrier_date, '')::timestamp,
       NULLIF(order_delivered_customer_date, '')::timestamp,
       NULLIF(order_estimated_delivery_date, '')::timestamp
FROM staging.orders;

INSERT INTO core.order_items
SELECT order_id,
       order_item_id::smallint,
       product_id,
       seller_id,
       NULLIF(shipping_limit_date, '')::timestamp,
       price::numeric(10,2),
       freight_value::numeric(10,2)
FROM staging.order_items;

INSERT INTO core.order_payments
SELECT order_id,
       payment_sequential::smallint,
       payment_type,
       NULLIF(payment_installments, '')::smallint,
       payment_value::numeric(10,2)
FROM staging.order_payments;

INSERT INTO core.order_reviews
SELECT review_id,
       order_id,
       review_score::smallint,
       NULLIF(review_comment_title, ''),
       NULLIF(review_comment_message, ''),
       NULLIF(review_creation_date, '')::timestamp,
       NULLIF(review_answer_timestamp, '')::timestamp
FROM staging.order_reviews;

-- ---------------------------------------------------------------------
-- 3. Secondary indexes
--    Foreign key columns used in joins, plus columns used for filtering.
--    (Primary keys are indexed automatically.)
-- ---------------------------------------------------------------------

CREATE INDEX idx_customers_unique_id   ON core.customers   (customer_unique_id);
CREATE INDEX idx_orders_customer_id    ON core.orders      (customer_id);
CREATE INDEX idx_orders_purchased_at   ON core.orders      (purchased_at);
CREATE INDEX idx_order_items_product   ON core.order_items (product_id);
CREATE INDEX idx_order_items_seller    ON core.order_items (seller_id);
CREATE INDEX idx_order_reviews_order   ON core.order_reviews (order_id);
CREATE INDEX idx_products_category     ON core.products    (category_name);

-- ---------------------------------------------------------------------
-- 4. Documentation stored in the database itself
-- ---------------------------------------------------------------------

COMMENT ON TABLE core.orders        IS 'One row per order, with lifecycle timestamps.';
COMMENT ON TABLE core.order_items   IS 'Line items of an order (product, seller, price, freight).';
COMMENT ON TABLE core.order_reviews IS 'Customer reviews; PK is (review_id, order_id) because review_id alone is not unique.';
COMMENT ON TABLE core.zip_locations IS 'One row per zip prefix, mean lat/lng of valid points (aggregated from 1M raw rows).';
COMMENT ON TABLE core.customers     IS 'customer_id is order-scoped; customer_unique_id identifies the real person.';

COMMIT;

ANALYZE;

-- ---------------------------------------------------------------------
-- 5. Verification
-- ---------------------------------------------------------------------

SELECT 'categories'      AS table_name, COUNT(*) AS row_count FROM core.categories
UNION ALL SELECT 'products',       COUNT(*) FROM core.products
UNION ALL SELECT 'zip_locations',  COUNT(*) FROM core.zip_locations
UNION ALL SELECT 'customers',      COUNT(*) FROM core.customers
UNION ALL SELECT 'sellers',        COUNT(*) FROM core.sellers
UNION ALL SELECT 'orders',         COUNT(*) FROM core.orders
UNION ALL SELECT 'order_items',    COUNT(*) FROM core.order_items
UNION ALL SELECT 'order_payments', COUNT(*) FROM core.order_payments
UNION ALL SELECT 'order_reviews',  COUNT(*) FROM core.order_reviews;

SELECT tc.table_name, tc.constraint_type, COUNT(*) AS constraints
FROM information_schema.table_constraints tc
WHERE tc.table_schema = 'core'
  AND tc.constraint_type IN ('PRIMARY KEY', 'FOREIGN KEY', 'CHECK')
  AND tc.constraint_name NOT LIKE '%_not_null'
GROUP BY tc.table_name, tc.constraint_type
ORDER BY tc.table_name, tc.constraint_type;