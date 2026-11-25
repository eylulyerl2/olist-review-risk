-- =====================================================================
-- 01_staging.sql
-- Loads the raw Olist CSV files into the "staging" schema as-is.
-- All columns are TEXT so no row is rejected during loading.
-- Typed and constrained tables are built from these in 02_core.sql.
-- Run with:
--   docker exec olist-db psql -U olist_user -d olist -f /sql/01_staging.sql
-- =====================================================================

DROP SCHEMA IF EXISTS staging CASCADE;
CREATE SCHEMA staging;

-- ---------------------------------------------------------------------
-- Table definitions (column order matches the CSV headers)
-- ---------------------------------------------------------------------

CREATE TABLE staging.customers (
    customer_id               TEXT,
    customer_unique_id        TEXT,
    customer_zip_code_prefix  TEXT,
    customer_city             TEXT,
    customer_state            TEXT
);

CREATE TABLE staging.geolocation (
    geolocation_zip_code_prefix  TEXT,
    geolocation_lat              TEXT,
    geolocation_lng              TEXT,
    geolocation_city             TEXT,
    geolocation_state            TEXT
);

CREATE TABLE staging.orders (
    order_id                       TEXT,
    customer_id                    TEXT,
    order_status                   TEXT,
    order_purchase_timestamp       TEXT,
    order_approved_at              TEXT,
    order_delivered_carrier_date   TEXT,
    order_delivered_customer_date  TEXT,
    order_estimated_delivery_date  TEXT
);

CREATE TABLE staging.order_items (
    order_id             TEXT,
    order_item_id        TEXT,
    product_id           TEXT,
    seller_id            TEXT,
    shipping_limit_date  TEXT,
    price                TEXT,
    freight_value        TEXT
);

CREATE TABLE staging.order_payments (
    order_id              TEXT,
    payment_sequential    TEXT,
    payment_type          TEXT,
    payment_installments  TEXT,
    payment_value         TEXT
);

CREATE TABLE staging.order_reviews (
    review_id                TEXT,
    order_id                 TEXT,
    review_score             TEXT,
    review_comment_title     TEXT,
    review_comment_message   TEXT,
    review_creation_date     TEXT,
    review_answer_timestamp  TEXT
);

CREATE TABLE staging.products (
    product_id                  TEXT,
    product_category_name       TEXT,
    product_name_lenght         TEXT,
    product_description_lenght  TEXT,
    product_photos_qty          TEXT,
    product_weight_g            TEXT,
    product_length_cm           TEXT,
    product_height_cm           TEXT,
    product_width_cm            TEXT
);

CREATE TABLE staging.sellers (
    seller_id               TEXT,
    seller_zip_code_prefix  TEXT,
    seller_city             TEXT,
    seller_state            TEXT
);

CREATE TABLE staging.category_translation (
    product_category_name          TEXT,
    product_category_name_english  TEXT
);

-- ---------------------------------------------------------------------
-- Bulk load with server-side COPY (files are mounted at /data/raw)
-- ---------------------------------------------------------------------

COPY staging.customers            FROM '/data/raw/olist_customers_dataset.csv'          WITH (FORMAT csv, HEADER true);
COPY staging.geolocation          FROM '/data/raw/olist_geolocation_dataset.csv'        WITH (FORMAT csv, HEADER true);
COPY staging.orders               FROM '/data/raw/olist_orders_dataset.csv'             WITH (FORMAT csv, HEADER true);
COPY staging.order_items          FROM '/data/raw/olist_order_items_dataset.csv'        WITH (FORMAT csv, HEADER true);
COPY staging.order_payments       FROM '/data/raw/olist_order_payments_dataset.csv'     WITH (FORMAT csv, HEADER true);
COPY staging.order_reviews        FROM '/data/raw/olist_order_reviews_dataset.csv'      WITH (FORMAT csv, HEADER true);
COPY staging.products             FROM '/data/raw/olist_products_dataset.csv'           WITH (FORMAT csv, HEADER true);
COPY staging.sellers              FROM '/data/raw/olist_sellers_dataset.csv'            WITH (FORMAT csv, HEADER true);
COPY staging.category_translation FROM '/data/raw/product_category_name_translation.csv' WITH (FORMAT csv, HEADER true);

-- ---------------------------------------------------------------------
-- Row counts for verification
-- ---------------------------------------------------------------------

SELECT 'customers'            AS table_name, COUNT(*) AS row_count FROM staging.customers
UNION ALL SELECT 'geolocation',          COUNT(*) FROM staging.geolocation
UNION ALL SELECT 'orders',               COUNT(*) FROM staging.orders
UNION ALL SELECT 'order_items',          COUNT(*) FROM staging.order_items
UNION ALL SELECT 'order_payments',       COUNT(*) FROM staging.order_payments
UNION ALL SELECT 'order_reviews',        COUNT(*) FROM staging.order_reviews
UNION ALL SELECT 'products',             COUNT(*) FROM staging.products
UNION ALL SELECT 'sellers',              COUNT(*) FROM staging.sellers
UNION ALL SELECT 'category_translation', COUNT(*) FROM staging.category_translation;