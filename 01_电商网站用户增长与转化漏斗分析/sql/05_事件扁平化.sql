-- Purpose: Create a flat event table from nested GA4 raw events.
-- Before running, replace `ga4-growth-analysis` with your actual Google Cloud project ID if needed.
-- This table is the recommended local-export source, not the original nested GA4 table.

CREATE SCHEMA IF NOT EXISTS `ga4-growth-analysis.ga4_growth`
OPTIONS(location = 'US');

CREATE OR REPLACE TABLE `ga4-growth-analysis.ga4_growth.flat_events` AS
SELECT
  PARSE_DATE('%Y%m%d', event_date) AS event_dt,
  TIMESTAMP_MICROS(event_timestamp) AS event_time,
  user_pseudo_id,
  (SELECT ANY_VALUE(value.int_value) FROM UNNEST(event_params) WHERE key = 'ga_session_id') AS ga_session_id,
  CONCAT(
    user_pseudo_id,
    '-',
    CAST((SELECT ANY_VALUE(value.int_value) FROM UNNEST(event_params) WHERE key = 'ga_session_id') AS STRING)
  ) AS session_key,
  event_name,
  platform,
  device.category AS device_category,
  device.operating_system AS operating_system,
  device.language AS device_language,
  geo.country AS country,
  geo.region AS region,
  geo.city AS city,
  traffic_source.source AS user_source,
  traffic_source.medium AS user_medium,
  traffic_source.name AS user_campaign,
  (SELECT ANY_VALUE(value.string_value) FROM UNNEST(event_params) WHERE key = 'page_location') AS page_location,
  (SELECT ANY_VALUE(value.string_value) FROM UNNEST(event_params) WHERE key = 'page_title') AS page_title,
  ecommerce.transaction_id AS transaction_id,
  ecommerce.purchase_revenue AS purchase_revenue,
  ecommerce.purchase_revenue_in_usd AS purchase_revenue_usd,
  ecommerce.total_item_quantity AS total_item_quantity,
  ecommerce.unique_items AS unique_items
FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
WHERE event_name IN (
  'first_visit',
  'session_start',
  'page_view',
  'view_item',
  'add_to_cart',
  'begin_checkout',
  'add_shipping_info',
  'add_payment_info',
  'purchase',
  'view_search_results',
  'select_item',
  'view_promotion',
  'select_promotion'
);
