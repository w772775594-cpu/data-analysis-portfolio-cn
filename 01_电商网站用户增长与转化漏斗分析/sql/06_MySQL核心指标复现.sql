-- GA4 Growth Analysis - MySQL core metric reproduction
-- Date: 2026-07-09
-- Tool: local MySQL Workbench
-- Source table: ga4_growth.flat_events
--
-- 目标：
-- 1. 用 MySQL 复现 Python / pandas 展示版 notebook 的核心口径。
-- 2. 为 Tableau v1 准备可导出的汇总表。
-- 3. 把每个指标的结果粒度、分母分子和数据质量限制写清楚。
--
-- 注意：
-- 1. flat_events 是从 CSV 导入的表，当前字段大多是 text。
-- 2. 本文件先创建 v_flat_events_clean 视图，统一处理日期、金额、有效订单、渠道字段。
-- 3. MySQL Workbench 结果导出建议用 Result Grid 的 Export 按钮导出 CSV。

CREATE DATABASE IF NOT EXISTS ga4_growth;
USE ga4_growth;

-- ============================================================
-- 0. 基础导入检查
-- 目标：确认 CSV 已经导入 MySQL，且行数、用户数、日期范围符合预期。
-- 结果粒度：每个 SELECT 返回一张检查表。
-- ============================================================
SHOW COLUMNS FROM flat_events;

SELECT
    COUNT(*) AS row_count,
    COUNT(DISTINCT user_pseudo_id) AS user_count,
    MIN(event_dt) AS min_event_dt,
    MAX(event_dt) AS max_event_dt,
    COUNT(DISTINCT event_name) AS event_type_count
FROM flat_events;

SELECT
    event_name,
    COUNT(*) AS event_rows,
    COUNT(DISTINCT user_pseudo_id) AS users
FROM flat_events
GROUP BY event_name
ORDER BY event_rows DESC;


-- ============================================================
-- 1. 清洗视图：v_flat_events_clean
-- 目标：把 text 导入字段统一转换成后续计算需要的字段。
-- 结果粒度：一行仍代表一次 GA4 用户事件。
--
-- 核心口径：
-- event_date = CAST(event_dt AS DATE)
-- event_time_dt = 从 event_time 文本解析出的 DATETIME(6)
-- is_purchase = event_name = 'purchase'
-- valid_order_id = purchase 事件中有效 transaction_id
-- revenue_amount = purchase_revenue_usd 转成数值，无法转换则按 0
-- source_medium = user_source / user_medium，空值填 unknown
-- ============================================================

CREATE OR REPLACE VIEW v_flat_events_clean AS
SELECT
    CAST(event_dt AS DATE) AS event_date,
    STR_TO_DATE(SUBSTRING(event_time, 1, 26), '%Y-%m-%d %H:%i:%s.%f') AS event_time_dt,
    user_pseudo_id,
    ga_session_id,
    session_key,
    event_name,
    platform,
    device_category,
    operating_system,
    device_language,
    country,
    region,
    city,
    COALESCE(NULLIF(user_source, ''), 'unknown') AS user_source_clean,
    COALESCE(NULLIF(user_medium, ''), 'unknown') AS user_medium_clean,
    COALESCE(NULLIF(user_campaign, ''), 'unknown') AS user_campaign_clean,
    CONCAT(
        COALESCE(NULLIF(user_source, ''), 'unknown'),
        ' / ',
        COALESCE(NULLIF(user_medium, ''), 'unknown')
    ) AS source_medium,
    page_location,
    page_title,
    transaction_id,
    CASE
        WHEN event_name = 'purchase'
             AND transaction_id IS NOT NULL
             AND transaction_id <> ''
             AND transaction_id <> '(not set)'
        THEN transaction_id
        ELSE NULL
    END AS valid_order_id,
    CASE
        WHEN purchase_revenue_usd REGEXP '^-?[0-9]+(\\.[0-9]+)?$'
        THEN CAST(purchase_revenue_usd AS DECIMAL(12, 2))
        ELSE 0
    END AS revenue_amount,
    purchase_revenue,
    purchase_revenue_usd,
    total_item_quantity,
    unique_items
FROM flat_events;


-- ============================================================
-- 2. 基础规模指标
-- 目标：复现 notebook 的基础审计。
-- 结果粒度：整张分析表一行。
--
-- 指标说明：
-- events = 事件行数
-- users = 去重 user_pseudo_id
-- purchase_events = purchase 事件行数
-- purchase_users = 发生 purchase 事件的去重用户数
-- valid_orders = 有效交易 ID 去重数
-- total_revenue = purchase_revenue_usd 汇总
-- ============================================================

SELECT
    COUNT(*) AS events,
    COUNT(DISTINCT user_pseudo_id) AS users,
    COUNT(DISTINCT event_date) AS date_count,
    MIN(event_date) AS min_event_date,
    MAX(event_date) AS max_event_date,
    COUNT(DISTINCT event_name) AS event_type_count,
    SUM(event_name = 'purchase') AS purchase_events,
    COUNT(DISTINCT CASE WHEN event_name = 'purchase' THEN user_pseudo_id END) AS purchase_users,
    COUNT(DISTINCT valid_order_id) AS valid_orders,
    SUM(revenue_amount) AS total_revenue
FROM v_flat_events_clean;


-- ============================================================
-- 3. 漏斗步骤用户数：funnel_summary_mysql
-- 目标：复现展示版 notebook 的步骤到达漏斗。
-- 结果粒度：一行代表一个漏斗步骤。
--
-- 漏斗路径：
-- view_item -> add_to_cart -> begin_checkout -> add_payment_info -> purchase
--
-- 当前口径：
-- users = 触发过该步骤事件的去重用户数
-- step_conversion_rate = 当前步骤 users / 上一步 users
-- overall_conversion_rate = 当前步骤 users / view_item users
-- drop_users_from_previous = 上一步 users - 当前步骤 users
--
-- 限制：
-- 当前不是严格顺序漏斗，没有校验同一用户是否按时间先后完成每一步。
-- ============================================================

CREATE OR REPLACE VIEW funnel_summary_mysql AS
SELECT
    step_order,
    step_name,
    event_name,
    users,
    LAG(users) OVER (ORDER BY step_order) AS prev_users,
    users / NULLIF(LAG(users) OVER (ORDER BY step_order), 0) AS step_conversion_rate,
    users / NULLIF(FIRST_VALUE(users) OVER (ORDER BY step_order), 0) AS overall_conversion_rate,
    LAG(users) OVER (ORDER BY step_order) - users AS drop_users_from_previous
FROM (
    SELECT
        1 AS step_order,
        '商品浏览' AS step_name,
        'view_item' AS event_name,
        COUNT(DISTINCT CASE WHEN event_name = 'view_item' THEN user_pseudo_id END) AS users
    FROM v_flat_events_clean

    UNION ALL

    SELECT
        2 AS step_order,
        '加购' AS step_name,
        'add_to_cart' AS event_name,
        COUNT(DISTINCT CASE WHEN event_name = 'add_to_cart' THEN user_pseudo_id END) AS users
    FROM v_flat_events_clean

    UNION ALL

    SELECT
        3 AS step_order,
        '开始结账' AS step_name,
        'begin_checkout' AS event_name,
        COUNT(DISTINCT CASE WHEN event_name = 'begin_checkout' THEN user_pseudo_id END) AS users
    FROM v_flat_events_clean

    UNION ALL

    SELECT
        4 AS step_order,
        '支付信息' AS step_name,
        'add_payment_info' AS event_name,
        COUNT(DISTINCT CASE WHEN event_name = 'add_payment_info' THEN user_pseudo_id END) AS users
    FROM v_flat_events_clean

    UNION ALL

    SELECT
        5 AS step_order,
        '购买' AS step_name,
        'purchase' AS event_name,
        COUNT(DISTINCT CASE WHEN event_name = 'purchase' THEN user_pseudo_id END) AS users
    FROM v_flat_events_clean
) AS funnel_steps;

SELECT *
FROM funnel_summary_mysql
ORDER BY step_order;

SELECT
    step_name AS biggest_drop_step,
    prev_users,
    users,
    drop_users_from_previous,
    step_conversion_rate
FROM funnel_summary_mysql
WHERE drop_users_from_previous IS NOT NULL
ORDER BY drop_users_from_previous DESC
LIMIT 1;


-- ============================================================
-- 4. 每日 KPI 趋势：daily_kpi_summary_mysql
-- 目标：为 Tableau 总览页准备日趋势表。
-- 结果粒度：一行代表一个 event_date。
--
-- 建议导出路径：
-- data/processed/daily_kpi_summary.csv
-- ============================================================

CREATE OR REPLACE VIEW daily_kpi_summary_mysql AS
SELECT
    event_date,
    COUNT(*) AS events,
    COUNT(DISTINCT user_pseudo_id) AS active_users,
    COUNT(DISTINCT CASE WHEN event_name = 'purchase' THEN user_pseudo_id END) AS purchase_users,
    COUNT(DISTINCT valid_order_id) AS valid_orders,
    SUM(revenue_amount) AS total_revenue,
    COUNT(DISTINCT CASE WHEN event_name = 'purchase' THEN user_pseudo_id END)
        / NULLIF(COUNT(DISTINCT user_pseudo_id), 0) AS buyer_rate,
    SUM(revenue_amount)
        / NULLIF(COUNT(DISTINCT user_pseudo_id), 0) AS revenue_per_user
FROM v_flat_events_clean
GROUP BY event_date;

SELECT *
FROM daily_kpi_summary_mysql
ORDER BY event_date;


-- ============================================================
-- 5. 用户级特征视图：user_features_mysql
-- 目标：为活跃分层、购买分层、渠道分层准备用户级底表。
-- 结果粒度：一行代表一个 user_pseudo_id。
--
-- 字段说明：
-- event_count = 用户事件数
-- active_days = 用户活跃过的去重日期数
-- valid_order_count = 有效订单数
-- total_revenue = 用户收入贡献
-- is_buyer = valid_order_count > 0
-- source_medium = 用户首次出现记录中的 source / medium
-- ============================================================

CREATE OR REPLACE VIEW user_features_mysql AS
WITH user_activity AS (
    SELECT
        user_pseudo_id,
        MIN(event_date) AS first_active_date,
        MAX(event_date) AS last_active_date,
        COUNT(DISTINCT event_date) AS active_days,
        COUNT(*) AS event_count,
        SUM(event_name = 'view_item') AS view_item_count,
        SUM(event_name = 'add_to_cart') AS add_to_cart_count
    FROM v_flat_events_clean
    GROUP BY user_pseudo_id
),
user_purchase AS (
    SELECT
        user_pseudo_id,
        SUM(event_name = 'purchase') AS purchase_event_count,
        COUNT(DISTINCT valid_order_id) AS valid_order_count,
        SUM(revenue_amount) AS total_revenue
    FROM v_flat_events_clean
    GROUP BY user_pseudo_id
),
first_channel AS (
    SELECT
        user_pseudo_id,
        source_medium
    FROM (
        SELECT
            user_pseudo_id,
            source_medium,
            ROW_NUMBER() OVER (
                PARTITION BY user_pseudo_id
                ORDER BY event_time_dt, event_date
            ) AS rn
        FROM v_flat_events_clean
    ) AS ranked_channel
    WHERE rn = 1
)
SELECT
    a.user_pseudo_id,
    a.first_active_date,
    a.last_active_date,
    a.active_days,
    a.event_count,
    a.view_item_count,
    a.add_to_cart_count,
    COALESCE(p.purchase_event_count, 0) AS purchase_event_count,
    COALESCE(p.valid_order_count, 0) AS valid_order_count,
    COALESCE(p.total_revenue, 0) AS total_revenue,
    CASE WHEN COALESCE(p.valid_order_count, 0) > 0 THEN 1 ELSE 0 END AS is_buyer,
    CASE
        WHEN a.event_count = 1 THEN '低活跃'
        WHEN a.event_count = 2 THEN '中活跃'
        ELSE '高活跃'
    END AS active_segment,
    CASE
        WHEN COALESCE(p.valid_order_count, 0) > 0 THEN '已购买'
        ELSE '未购买'
    END AS purchase_segment,
    COALESCE(c.source_medium, 'unknown / unknown') AS source_medium
FROM user_activity AS a
LEFT JOIN user_purchase AS p
    ON a.user_pseudo_id = p.user_pseudo_id
LEFT JOIN first_channel AS c
    ON a.user_pseudo_id = c.user_pseudo_id;

SELECT *
FROM user_features_mysql
LIMIT 100;


-- ============================================================
-- 6. 活跃分层汇总：active_segment_summary_mysql
-- 目标：对比低 / 中 / 高活跃用户的规模、购买率和收入贡献。
-- 结果粒度：一行代表一个 active_segment。
--
-- 建议导出路径：
-- data/processed/active_segment_summary.csv
-- ============================================================

CREATE OR REPLACE VIEW active_segment_summary_mysql AS
SELECT
    active_segment,
    COUNT(*) AS users,
    SUM(is_buyer) AS buyers,
    SUM(valid_order_count) AS valid_orders,
    SUM(total_revenue) AS total_revenue,
    AVG(active_days) AS avg_active_days,
    AVG(event_count) AS avg_event_count,
    SUM(is_buyer) / NULLIF(COUNT(*), 0) AS buyer_rate,
    SUM(total_revenue) / NULLIF(COUNT(*), 0) AS revenue_per_user
FROM user_features_mysql
GROUP BY active_segment;

SELECT *
FROM active_segment_summary_mysql
ORDER BY FIELD(active_segment, '低活跃', '中活跃', '高活跃');


-- ============================================================
-- 7. 购买分层汇总：purchase_segment_summary_mysql
-- 目标：对比已购买和未购买用户的活跃差异。
-- 结果粒度：一行代表一个 purchase_segment。
--
-- 建议导出路径：
-- data/processed/purchase_segment_summary.csv
-- ============================================================

CREATE OR REPLACE VIEW purchase_segment_summary_mysql AS
SELECT
    purchase_segment,
    COUNT(*) AS users,
    SUM(is_buyer) AS buyers,
    AVG(active_days) AS avg_active_days,
    AVG(event_count) AS avg_event_count,
    SUM(valid_order_count) AS valid_orders,
    SUM(total_revenue) AS total_revenue,
    SUM(is_buyer) / NULLIF(COUNT(*), 0) AS buyer_rate,
    SUM(total_revenue) / NULLIF(COUNT(*), 0) AS revenue_per_user
FROM user_features_mysql
GROUP BY purchase_segment;

SELECT *
FROM purchase_segment_summary_mysql
ORDER BY purchase_segment;


-- ============================================================
-- 8. 渠道分层汇总：channel_segment_summary_mysql
-- 目标：为 Tableau 渠道质量页准备数据。
-- 结果粒度：一行代表一个 source_medium。
--
-- 注意：
-- 1. source_medium 来自用户首次出现记录，不一定等于每次 session 来源。
-- 2. <Other> / (data deleted) / unknown 要单独保留，不能解释成具体渠道。
--
-- 建议导出路径：
-- data/processed/channel_segment_summary.csv
-- ============================================================

CREATE OR REPLACE VIEW channel_segment_summary_mysql AS
SELECT
    source_medium,
    COUNT(*) AS users,
    SUM(is_buyer) AS buyers,
    SUM(valid_order_count) AS valid_orders,
    SUM(total_revenue) AS total_revenue,
    SUM(is_buyer) / NULLIF(COUNT(*), 0) AS buyer_rate,
    SUM(total_revenue) / NULLIF(COUNT(*), 0) AS revenue_per_user
FROM user_features_mysql
GROUP BY source_medium;

SELECT *
FROM channel_segment_summary_mysql
ORDER BY users DESC;


-- ============================================================
-- 9. 数据质量检查
-- 目标：检查 MySQL 结果是否存在明显口径错误。
-- ============================================================

-- 9.1 用户级表是否一行一个用户
SELECT
    COUNT(*) AS user_features_rows,
    COUNT(DISTINCT user_pseudo_id) AS distinct_users,
    COUNT(*) - COUNT(DISTINCT user_pseudo_id) AS duplicated_user_rows
FROM user_features_mysql;

-- 9.2 summary 表用户数是否能对回总用户数
SELECT
    'active_segment_summary' AS table_name,
    SUM(users) AS summary_users,
    (SELECT COUNT(DISTINCT user_pseudo_id) FROM v_flat_events_clean) AS source_users
FROM active_segment_summary_mysql

UNION ALL

SELECT
    'purchase_segment_summary' AS table_name,
    SUM(users) AS summary_users,
    (SELECT COUNT(DISTINCT user_pseudo_id) FROM v_flat_events_clean) AS source_users
FROM purchase_segment_summary_mysql

UNION ALL

SELECT
    'channel_segment_summary' AS table_name,
    SUM(users) AS summary_users,
    (SELECT COUNT(DISTINCT user_pseudo_id) FROM v_flat_events_clean) AS source_users
FROM channel_segment_summary_mysql;

-- 9.3 非 buyer 但有收入的用户
-- 如果有结果，说明 valid_order_id 和 revenue_amount 字段存在不完全一致。
SELECT
    COUNT(*) AS non_buyer_positive_revenue_users
FROM user_features_mysql
WHERE is_buyer = 0
  AND total_revenue > 0;

SELECT
    user_pseudo_id,
    purchase_event_count,
    valid_order_count,
    total_revenue
FROM user_features_mysql
WHERE is_buyer = 0
  AND total_revenue > 0
ORDER BY total_revenue DESC
LIMIT 20;

-- 9.4 渠道中 Other / data deleted / unknown 占比
SELECT
    source_medium,
    COUNT(*) AS users,
    COUNT(*) / NULLIF((SELECT COUNT(*) FROM user_features_mysql), 0) AS user_share
FROM user_features_mysql
WHERE source_medium LIKE '%<Other>%'
   OR source_medium LIKE '%data deleted%'
   OR source_medium LIKE '%unknown%'
GROUP BY source_medium
ORDER BY users DESC;


-- ============================================================
-- 10. Tableau 导出查询清单
-- 目标：在 Workbench 里逐个运行 SELECT，然后用 Result Grid Export 导出 CSV。
-- ============================================================

-- 10.1 导出：data/processed/funnel_summary.csv
SELECT *
FROM funnel_summary_mysql
ORDER BY step_order;

-- 10.2 导出：data/processed/daily_kpi_summary.csv
SELECT *
FROM daily_kpi_summary_mysql
ORDER BY event_date;

-- 10.3 导出：data/processed/active_segment_summary.csv
SELECT *
FROM active_segment_summary_mysql
ORDER BY FIELD(active_segment, '低活跃', '中活跃', '高活跃');

-- 10.4 导出：data/processed/purchase_segment_summary.csv
SELECT *
FROM purchase_segment_summary_mysql
ORDER BY purchase_segment;

-- 10.5 导出：data/processed/channel_segment_summary.csv
SELECT *
FROM channel_segment_summary_mysql
ORDER BY users DESC;


-- ============================================================
-- 11. 后续增强：严格顺序漏斗思路
-- 当前不要求今天完成，只作为 v2 提醒。
--
-- 口径：
-- 1. 每个用户先取各漏斗步骤的首次时间。
-- 2. 后一步时间必须晚于前一步时间。
-- 3. 也可以改成 session_key 粒度，做 session 内严格顺序漏斗。
-- ============================================================
