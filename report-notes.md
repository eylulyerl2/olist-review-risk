# Report Notes

## Implementation & Setup – Database environment

- The database runs in a Docker container using the official `postgres:16` image
  (PostgreSQL 16.15), defined in a `docker-compose.yml` file so the whole
  environment can be started with a single command: `docker compose up -d`.
- Credentials are stored in a separate `.env` file that is excluded from version
  control via `.gitignore`.
- The container exposes PostgreSQL on host port 5434 (mapped to the default
  container port 5432) to avoid conflicts with other local PostgreSQL instances.
- A named Docker volume (`olist_pgdata`) persists the database files, so data
  survives container restarts or re-creation.
- The raw Olist CSV files are mounted read-only into the container at `/data/raw`,
  allowing them to be bulk-loaded with PostgreSQL's server-side `COPY` command.
- A healthcheck based on `pg_isready` confirms the database is ready to accept
  connections.
- DBeaver (with the PostgreSQL JDBC driver 42.7.13) is used as a GUI client to
  inspect the schema and run queries.
- Dataset: Brazilian E-Commerce Public Dataset by Olist (Kaggle), 9 CSV files,
  ~121 MB in total.
  
## Data loading – Staging layer

- The raw CSV files were loaded into a dedicated `staging` schema using
  PostgreSQL's server-side `COPY ... WITH (FORMAT csv, HEADER true)` command
  (script: `sql/01_staging.sql`).
- All staging columns are `TEXT`, so no rows are rejected because of type
  errors; type conversion and validation happen in the next layer.
- Loaded row counts: orders 99,441; customers 99,441; order_items 112,650;
  order_payments 103,886; order_reviews 99,224; products 32,951; sellers 3,095;
  category_translation 71; geolocation 1,000,163.
- Note: the reviews file has 104,720 physical lines but only 99,224 records,
  because some review comments contain line breaks inside quoted fields. A
  proper CSV parser (PostgreSQL COPY in CSV mode) handles this correctly.
- The script is idempotent: it drops and recreates the staging schema, so it
  can be re-run safely.
  
## Data quality profiling (sql/02_profile_staging.sql)

- Natural keys are unique: order_id, customer_id, product_id, seller_id;
  (order_id, order_item_id) and (order_id, payment_sequential) are unique
  composite keys.
- All referential checks returned 0 violations (items -> products/sellers,
  reviews -> orders), so foreign keys can be enforced without dropping data.
- 99,441 customer_id values map to 96,096 customer_unique_id values: customer_id
  is order-scoped, customer_unique_id identifies the real person (indexed).
- review_id alone is NOT unique (814 duplicates) but (review_id, order_id) is,
  so it is used as the composite primary key of order_reviews.
- 547 orders have more than one review -> the most recent review is used as the
  label. 768 orders have no review -> excluded from training but scored by the
  model (realistic "not yet reviewed" use case).
- Class imbalance: 14.69% of reviews are negative (1-2 stars). Accuracy alone
  is misleading; precision, recall and F1 are the primary metrics.
- Scope: 2,963 orders are not delivered and 8 delivered orders lack a delivery
  date. The prediction moment is "right after delivery", so the model uses
  delivered orders with a delivery date.
- 610 products have no category (kept as NULL, treated as "unknown"); 2
  categories lack an English translation (fallback: original name).
- Geolocation has 1,000,163 rows but only 19,015 distinct zip prefixes, so it is
  aggregated to one row per zip prefix (mean lat/lng) before use.
  
## Database design – Core layer (sql/03_core.sql)

- A normalized `core` schema (9 tables) is built from staging inside a single
  transaction (BEGIN ... COMMIT) with ON_ERROR_STOP, so a failure leaves no
  partially built schema.
- Data types: timestamps as TIMESTAMP, monetary values as NUMERIC(10,2),
  review score as SMALLINT, hash identifiers as VARCHAR(32). Zip code prefixes
  are kept as text to preserve leading zeros (e.g. "01037").
- Integrity is enforced by the database: 9 primary keys, 7 foreign keys
  (orders->customers; order_items->orders/products/sellers;
  order_payments->orders; order_reviews->orders; products->categories) and
  4 CHECK constraints (non-negative price, freight and payment value; review
  score between 1 and 5).
- Composite primary keys: order_items (order_id, order_item_id),
  order_payments (order_id, payment_sequential), order_reviews
  (review_id, order_id).
- No rows were lost during type conversion: all row counts match staging.
- categories (73 rows) = 71 translated categories + 2 untranslated ones
  (fallback: original Portuguese name).
- zip_locations: 1,000,163 raw geolocation rows aggregated to 19,010 zip
  prefixes (mean lat/lng); points outside Brazil's bounding box were discarded
  as invalid (5 zip prefixes had only invalid points).
- Secondary B-tree indexes on foreign key / filter columns:
  customers(customer_unique_id), orders(customer_id), orders(purchased_at),
  order_items(product_id), order_items(seller_id), order_reviews(order_id),
  products(category_name). Primary keys are indexed automatically.
- Table comments are stored in the database (COMMENT ON TABLE) as built-in
  documentation.
  
## Feature engineering – ml.order_features view (sql/04_features.sql)

- A SQL view in the `ml` schema computes one row per delivered order with
  model features and the label. The Python model reads its training data
  directly from this view (no CSV export).
- Scope: 96,470 delivered orders with a delivery date; 95,824 are labeled and
  646 have no review (scored later by the model).
- Label: `is_negative = 1` if the most recent review score is 1 or 2.
  Negative rate within scope: 12.81% (lower than the overall 14.69% because
  undelivered orders, which mostly receive bad reviews, are out of scope).
- Feature groups: delivery (delivery days, estimated days, delay days, late
  flag, approval hours, carrier hand-off days), basket (items, products,
  sellers, total price, freight, freight ratio), payment (total, installments,
  main payment type), product (main category, weight, photos, description
  length), location (customer/seller state, same-state flag, customer-seller
  distance), customer history (number of earlier orders of the same person,
  computed with a window function to avoid future leakage) and purchase
  weekday.
- Customer-seller distance is computed in SQL with the Haversine formula from
  zip centroids; it is NULL for 477 orders whose zip has no valid coordinates.
- Bug found during validation: PostgreSQL's LEAST() ignores NULLs, so missing
  coordinates initially produced ~20,015 km distances. The NULL case is now
  handled explicitly; after the fix there are 0 implausible distances
  (max 3,399 km).
- Key insight: negative review rate is 9.22% for on-time deliveries vs 54.07%
  for late deliveries (about 6x higher).
  
## Python environment and database access

- Python 3.13.2 in a project-local virtual environment (`.venv`), with exact
  dependency versions pinned in `requirements.txt` for reproducibility:
  pandas 3.1.1, scikit-learn 1.9.1, SQLAlchemy 2.1.9, psycopg 3.3.9,
  python-dotenv 1.2.4.
- `src/db.py` builds a SQLAlchemy engine (`postgresql+psycopg` driver) from the
  values in `.env`, so credentials are never hard-coded in the source code.
- `src/check_connection.py` verifies the integration: Python connects to
  PostgreSQL 16.15 and reads `ml.order_features` directly with `pandas.read_sql`
  (96,470 orders, 95,824 labeled, 30 columns). No CSV export is involved.
- Of the 30 columns, 26 are model features; `order_id` (identifier),
  `purchased_at` (used for the time-based train/test split), `review_score` and
  `is_negative` (label) are excluded from the feature set to avoid data leakage.
- Development environment: Visual Studio Code with the Python and Container
  Tools extensions; DBeaver as the database GUI client.