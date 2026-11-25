-- =====================================================================
-- 02_profile_staging.sql
-- Data quality checks on the staging layer. The results justify the
-- primary keys, foreign keys and cleaning rules used in 03_core.sql.
-- Run with:
--   docker exec olist-db psql -U olist_user -d olist -f /sql/02_profile_staging.sql
-- =====================================================================

SELECT check_name, value
FROM (
    -- Key uniqueness
    SELECT 1 AS ord, 'orders: duplicate order_id' AS check_name,
           (COUNT(*) - COUNT(DISTINCT order_id))::numeric AS value
    FROM staging.orders
    UNION ALL
    SELECT 2, 'customers: duplicate customer_id',
           (COUNT(*) - COUNT(DISTINCT customer_id))::numeric
    FROM staging.customers
    UNION ALL
    SELECT 3, 'customers: distinct customer_unique_id',
           COUNT(DISTINCT customer_unique_id)::numeric
    FROM staging.customers
    UNION ALL
    SELECT 4, 'products: duplicate product_id',
           (COUNT(*) - COUNT(DISTINCT product_id))::numeric
    FROM staging.products
    UNION ALL
    SELECT 5, 'sellers: duplicate seller_id',
           (COUNT(*) - COUNT(DISTINCT seller_id))::numeric
    FROM staging.sellers
    UNION ALL
    SELECT 6, 'order_items: duplicate (order_id, order_item_id)',
           (COUNT(*) - COUNT(DISTINCT (order_id, order_item_id)))::numeric
    FROM staging.order_items
    UNION ALL
    SELECT 7, 'order_payments: duplicate (order_id, payment_sequential)',
           (COUNT(*) - COUNT(DISTINCT (order_id, payment_sequential)))::numeric
    FROM staging.order_payments

    -- Reviews (target variable)
    UNION ALL
    SELECT 10, 'reviews: duplicate review_id',
           (COUNT(*) - COUNT(DISTINCT review_id))::numeric
    FROM staging.order_reviews
    UNION ALL
    SELECT 11, 'reviews: duplicate (review_id, order_id)',
           (COUNT(*) - COUNT(DISTINCT (review_id, order_id)))::numeric
    FROM staging.order_reviews
    UNION ALL
    SELECT 12, 'reviews: orders with more than one review',
           COUNT(*)::numeric
    FROM (SELECT order_id FROM staging.order_reviews
          GROUP BY order_id HAVING COUNT(*) > 1) t
    UNION ALL
    SELECT 13, 'reviews: orders with no review',
           COUNT(*)::numeric
    FROM staging.orders o
    WHERE NOT EXISTS (SELECT 1 FROM staging.order_reviews r
                      WHERE r.order_id = o.order_id)
    UNION ALL
    SELECT 14, 'reviews: share of 1-2 star reviews (%)',
           ROUND(100.0 * AVG((review_score::int <= 2)::int), 2)
    FROM staging.order_reviews

    -- Orders and delivery
    UNION ALL
    SELECT 20, 'orders: status not delivered',
           COUNT(*)::numeric
    FROM staging.orders WHERE order_status <> 'delivered'
    UNION ALL
    SELECT 21, 'orders: delivered but missing delivery date',
           COUNT(*)::numeric
    FROM staging.orders
    WHERE order_status = 'delivered'
      AND COALESCE(order_delivered_customer_date, '') = ''

    -- Referential integrity
    UNION ALL
    SELECT 30, 'order_items: product_id not in products',
           COUNT(*)::numeric
    FROM staging.order_items i
    WHERE NOT EXISTS (SELECT 1 FROM staging.products p
                      WHERE p.product_id = i.product_id)
    UNION ALL
    SELECT 31, 'order_items: seller_id not in sellers',
           COUNT(*)::numeric
    FROM staging.order_items i
    WHERE NOT EXISTS (SELECT 1 FROM staging.sellers s
                      WHERE s.seller_id = i.seller_id)
    UNION ALL
    SELECT 32, 'reviews: order_id not in orders',
           COUNT(*)::numeric
    FROM staging.order_reviews r
    WHERE NOT EXISTS (SELECT 1 FROM staging.orders o
                      WHERE o.order_id = r.order_id)

    -- Products and categories
    UNION ALL
    SELECT 40, 'products: missing category',
           COUNT(*)::numeric
    FROM staging.products
    WHERE COALESCE(product_category_name, '') = ''
    UNION ALL
    SELECT 41, 'categories without English translation',
           COUNT(DISTINCT p.product_category_name)::numeric
    FROM staging.products p
    LEFT JOIN staging.category_translation t
           ON t.product_category_name = p.product_category_name
    WHERE COALESCE(p.product_category_name, '') <> ''
      AND t.product_category_name IS NULL

    -- Geolocation
    UNION ALL
    SELECT 50, 'geolocation: distinct zip prefixes',
           COUNT(DISTINCT geolocation_zip_code_prefix)::numeric
    FROM staging.geolocation
) checks
ORDER BY ord;