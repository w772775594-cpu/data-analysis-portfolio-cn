-- Purpose: Audit traffic-source availability and channel quality at user level.

SELECT
  COALESCE(traffic_source.source, '(null)') AS source,
  COALESCE(traffic_source.medium, '(null)') AS medium,
  COALESCE(traffic_source.name, '(null)') AS campaign,
  COUNT(*) AS event_count,
  COUNT(DISTINCT user_pseudo_id) AS user_count,
  COUNTIF(event_name = 'purchase') AS purchase_events,
  COUNT(DISTINCT IF(event_name = 'purchase', user_pseudo_id, NULL)) AS purchase_users,
  SUM(IF(event_name = 'purchase', ecommerce.purchase_revenue_in_usd, 0)) AS purchase_revenue_usd
FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
GROUP BY source, medium, campaign
ORDER BY user_count DESC
LIMIT 50;
