-- Purpose: Check date coverage, daily volume, active users, purchases, and revenue.

SELECT
  PARSE_DATE('%Y%m%d', event_date) AS event_dt,
  COUNT(*) AS event_count,
  COUNT(DISTINCT user_pseudo_id) AS active_users,
  COUNTIF(event_name = 'first_visit') AS first_visit_events,
  COUNT(DISTINCT IF(event_name = 'first_visit', user_pseudo_id, NULL)) AS first_visit_users,
  COUNTIF(event_name = 'purchase') AS purchase_events,
  COUNT(DISTINCT IF(event_name = 'purchase', user_pseudo_id, NULL)) AS purchase_users,
  SUM(IF(event_name = 'purchase', ecommerce.purchase_revenue_in_usd, 0)) AS purchase_revenue_usd
FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
GROUP BY event_dt
ORDER BY event_dt;
