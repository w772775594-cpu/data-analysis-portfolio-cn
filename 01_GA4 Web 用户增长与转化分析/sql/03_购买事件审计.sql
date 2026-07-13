-- Purpose: Audit purchase-event quality, transaction IDs, and revenue fields.

WITH purchases AS (
  SELECT
    PARSE_DATE('%Y%m%d', event_date) AS event_dt,
    TIMESTAMP_MICROS(event_timestamp) AS event_time,
    user_pseudo_id,
    ecommerce.transaction_id AS transaction_id,
    ecommerce.purchase_revenue AS purchase_revenue,
    ecommerce.purchase_revenue_in_usd AS purchase_revenue_usd,
    ecommerce.total_item_quantity AS total_item_quantity,
    ecommerce.unique_items AS unique_items
  FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
  WHERE event_name = 'purchase'
)
SELECT
  COUNT(*) AS purchase_events,
  COUNT(DISTINCT user_pseudo_id) AS purchase_users,
  COUNT(DISTINCT transaction_id) AS distinct_transactions,
  COUNTIF(transaction_id IS NULL OR transaction_id = '') AS missing_transaction_id_events,
  COUNTIF(purchase_revenue IS NULL) AS missing_purchase_revenue_events,
  COUNTIF(purchase_revenue_usd IS NULL) AS missing_purchase_revenue_usd_events,
  SUM(purchase_revenue) AS total_purchase_revenue,
  SUM(purchase_revenue_usd) AS total_purchase_revenue_usd,
  AVG(purchase_revenue_usd) AS avg_purchase_revenue_usd_per_event,
  MIN(purchase_revenue_usd) AS min_purchase_revenue_usd,
  MAX(purchase_revenue_usd) AS max_purchase_revenue_usd,
  COUNTIF(purchase_revenue_usd < 0) AS negative_revenue_events,
  COUNTIF(total_item_quantity IS NULL) AS missing_total_item_quantity_events,
  COUNTIF(unique_items IS NULL) AS missing_unique_items_events
FROM purchases;
