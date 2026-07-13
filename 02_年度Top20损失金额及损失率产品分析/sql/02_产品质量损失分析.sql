USE manufacturing_defect_loss;

SELECT COUNT(*) AS row_count
FROM defect_loss_fact;
SELECT *
FROM defect_loss_fact;

-- 创建每月每产品指标
DROP TABLE IF EXISTS product_month_metrics;

CREATE TABLE product_month_metrics AS
WITH process_pivot AS (
    SELECT
        `month`,
        sap_code,
        product_name,
        product_category,
        SUM(loss_qty) AS total_loss_qty,
        SUM(loss_amount) AS total_loss_amount,
		MAX(CASE WHEN process = 'casting' THEN defect_rate ELSE 0 END) AS casting_defect_rate,
		MAX(CASE WHEN process = 'machining' THEN defect_rate ELSE 0 END) AS machining_defect_rate,
		MAX(CASE WHEN process = 'polishing' THEN defect_rate ELSE 0 END) AS polishing_defect_rate
    FROM defect_loss_fact
    GROUP BY
        `month`,
        sap_code,
        product_name,
        product_category
)
SELECT
    *,
	1- (1 - casting_defect_rate)
      * (1 - machining_defect_rate)
      * (1 - polishing_defect_rate)
    AS composite_defect_rate
FROM process_pivot;
SELECT *
FROM product_month_metrics;

-- 每月损失金额TOP20
WITH amount_ranked AS (
    SELECT
        `month`,
        sap_code,
        product_name,
        product_category,
        total_loss_amount,
        ROW_NUMBER() OVER (
            PARTITION BY `month`
            ORDER BY total_loss_amount DESC
        ) AS amount_rn
    FROM product_month_metrics
)
SELECT *
FROM amount_ranked
WHERE amount_rn <= 20
ORDER BY `month`, amount_rn;

-- 每月不良率TOP20
WITH rate_ranked AS (
    SELECT
        `month`,
        sap_code,
        product_name,
        product_category,
        composite_defect_rate,
        ROW_NUMBER() OVER (
            PARTITION BY `month`
            ORDER BY composite_defect_rate DESC
        ) AS rate_rn
    FROM product_month_metrics
)
SELECT *
FROM rate_ranked
WHERE rate_rn <= 20
ORDER BY `month`, rate_rn;

-- 工序月度指标
DROP TABLE IF EXISTS process_month_metrics;

CREATE TABLE process_month_metrics AS
SELECT
    `month`,
    process,
    SUM(loss_qty) AS process_month_loss_qty,
    SUM(production_qty) AS process_month_production_qty,
    SUM(loss_amount) AS process_month_loss_amount,
    SUM(loss_qty) / NULLIF(SUM(production_qty), 0)
        AS process_month_defect_rate
FROM defect_loss_fact
GROUP BY
    `month`,
    process;
SELECT *
FROM process_month_metrics
ORDER BY `month`, process;

-- 产品不良损失金额和不良率月环比
WITH metrics_with_prev AS (
    SELECT
        *,
        LAG(total_loss_amount) OVER (
            PARTITION BY sap_code
            ORDER BY `month`
        ) AS prev_loss_amount,
        LAG(composite_defect_rate) OVER (
            PARTITION BY sap_code
            ORDER BY `month`
        ) AS prev_composite_defect_rate
    FROM product_month_metrics
)
SELECT
    *,
    (total_loss_amount - prev_loss_amount)
        / NULLIF(prev_loss_amount, 0) AS loss_amount_mom,
    (composite_defect_rate - prev_composite_defect_rate)
        / NULLIF(prev_composite_defect_rate, 0) AS composite_defect_rate_mom
FROM metrics_with_prev;


-- ============================================================
-- 数据质量问题明细表：一行代表一个具体问题
-- ============================================================

DROP TABLE IF EXISTS dq_issues;

CREATE TABLE dq_issues AS

-- 损失数量大于生产数量
SELECT
    'loss_qty_gt_production_qty' AS issue_type,
    `month`,
    sap_code,
    process,
    CONCAT(
        sap_code,
        '-',
        CASE process
            WHEN 'casting' THEN '004'
            WHEN 'machining' THEN '003'
            WHEN 'polishing' THEN '002'
        END
    ) AS defect_material_no,
    CONCAT(
        'loss_qty=', loss_qty,
        ', production_qty=', production_qty
    ) AS issue_detail
FROM defect_loss_fact
WHERE loss_qty > production_qty

UNION ALL

-- 有损失但单价为 0，会导致损失金额被低估
SELECT
    'loss_qty_gt0_unit_price_eq0' AS issue_type,
    `month`,
    sap_code,
    process,
    CONCAT(
        sap_code,
        '-',
        CASE process
            WHEN 'casting' THEN '004'
            WHEN 'machining' THEN '003'
            WHEN 'polishing' THEN '002'
        END
    ) AS defect_material_no,
    CONCAT(
        'loss_qty=', loss_qty,
        ', unit_price=', unit_price,
        ', loss_amount=', loss_amount
    ) AS issue_detail
FROM defect_loss_fact
WHERE loss_qty > 0
  AND unit_price = 0

UNION ALL

-- 有损失但生产数量为 0，需核对数据来源
SELECT
    'loss_qty_gt0_production_qty_eq0' AS issue_type,
    `month`,
    sap_code,
    process,
    CONCAT(
        sap_code,
        '-',
        CASE process
            WHEN 'casting' THEN '004'
            WHEN 'machining' THEN '003'
            WHEN 'polishing' THEN '002'
        END
    ) AS defect_material_no,
    CONCAT(
        'loss_qty=', loss_qty,
        ', production_qty=', production_qty,
        ', has_process_data=', has_process_data
    ) AS issue_detail
FROM defect_loss_fact
WHERE loss_qty > 0
  AND production_qty = 0

UNION ALL

-- 工序不在 casting、machining、polishing 范围内
SELECT
    'invalid_process' AS issue_type,
    `month`,
    sap_code,
    process,
    NULL AS defect_material_no,
    CONCAT('invalid process=', process) AS issue_detail
FROM defect_loss_fact
WHERE process NOT IN ('casting', 'machining', 'polishing')

UNION ALL

-- 月份不是 YYYY-MM 格式
SELECT
    'invalid_month_format' AS issue_type,
    `month`,
    sap_code,
    process,
    CONCAT(
        sap_code,
        '-',
        CASE process
            WHEN 'casting' THEN '004'
            WHEN 'machining' THEN '003'
            WHEN 'polishing' THEN '002'
        END
    ) AS defect_material_no,
    CONCAT('invalid month=', `month`) AS issue_detail
FROM defect_loss_fact
WHERE `month` NOT REGEXP '^[0-9]{4}-(0[1-9]|1[0-2])$'

UNION ALL

-- month + sap_code + process 重复
SELECT
    'duplicated_month_sap_process' AS issue_type,
    `month`,
    sap_code,
    process,
    CONCAT(
        sap_code,
        '-',
        CASE process
            WHEN 'casting' THEN '004'
            WHEN 'machining' THEN '003'
            WHEN 'polishing' THEN '002'
        END
    ) AS defect_material_no,
    CONCAT('duplicate row count=', COUNT(*)) AS issue_detail
FROM defect_loss_fact
GROUP BY
    `month`,
    sap_code,
    process
HAVING COUNT(*) > 1;


-- 数据质量结果检查

-- 当前模拟数据预期只有 78 行“有损失但单价为 0”问题
SELECT COUNT(*) AS dq_issue_row_count
FROM dq_issues;

-- 预期 loss_qty_gt0_unit_price_eq0 为 78，其余问题为 0
SELECT
    issue_type,
    COUNT(*) AS issue_count,
    COUNT(DISTINCT sap_code) AS affected_product_count
FROM dq_issues
GROUP BY issue_type
ORDER BY issue_count DESC, issue_type;

-- 查看数据质量问题明细
SELECT *
FROM dq_issues
ORDER BY
    issue_type,
    `month`,
    sap_code,
    process;


-- ============================================================
-- 将环比、排名和 Top20 标记正式写入指标表
-- ============================================================

-- 产品月指标最终表
DROP TABLE IF EXISTS product_month_metrics;

CREATE TABLE product_month_metrics AS
WITH process_pivot AS (
    SELECT
        `month`,
        sap_code,
        product_name,
        product_category,
        SUM(production_qty) AS total_production_qty,
        SUM(loss_qty) AS total_loss_qty,
        SUM(loss_amount) AS total_loss_amount,
        MAX(CASE WHEN process = 'casting' THEN defect_rate ELSE 0 END)
            AS casting_defect_rate,
        MAX(CASE WHEN process = 'machining' THEN defect_rate ELSE 0 END)
            AS machining_defect_rate,
        MAX(CASE WHEN process = 'polishing' THEN defect_rate ELSE 0 END)
            AS polishing_defect_rate
    FROM defect_loss_fact
    GROUP BY
        `month`,
        sap_code,
        product_name,
        product_category
),
composite_metrics AS (
    SELECT
        *,
        1 - (1 - casting_defect_rate)
            * (1 - machining_defect_rate)
            * (1 - polishing_defect_rate)
            AS composite_defect_rate
    FROM process_pivot
),
metrics_with_prev AS (
    SELECT
        *,
        LAG(total_loss_amount) OVER (
            PARTITION BY sap_code
            ORDER BY `month`
        ) AS prev_loss_amount,
        LAG(composite_defect_rate) OVER (
            PARTITION BY sap_code
            ORDER BY `month`
        ) AS prev_composite_defect_rate
    FROM composite_metrics
),
metrics_with_mom AS (
    SELECT
        *,
        (total_loss_amount - prev_loss_amount)
            / NULLIF(prev_loss_amount, 0) AS loss_amount_mom,
        (composite_defect_rate - prev_composite_defect_rate)
            / NULLIF(prev_composite_defect_rate, 0) AS composite_defect_rate_mom
    FROM metrics_with_prev
),
metrics_with_rank AS (
    SELECT
        *,
        ROW_NUMBER() OVER (
            PARTITION BY `month`
            ORDER BY total_loss_amount DESC, sap_code
        ) AS loss_amount_rank,
        ROW_NUMBER() OVER (
            PARTITION BY `month`
            ORDER BY composite_defect_rate DESC, sap_code
        ) AS composite_defect_rate_rank
    FROM metrics_with_mom
)
SELECT
    `month`,
    sap_code,
    product_name,
    product_category,
    total_production_qty,
    total_loss_qty,
    total_loss_amount,
    casting_defect_rate,
    machining_defect_rate,
    polishing_defect_rate,
    composite_defect_rate,
    loss_amount_mom,
    composite_defect_rate_mom,
    loss_amount_rank,
    loss_amount_rank <= 20 AS is_top20,
    composite_defect_rate_rank,
    composite_defect_rate_rank <= 20 AS is_composite_defect_top20
FROM metrics_with_rank;


-- 工序月指标最终表
DROP TABLE IF EXISTS process_month_metrics;

CREATE TABLE process_month_metrics AS
WITH process_base AS (
    SELECT
        `month`,
        process,
        SUM(loss_qty) AS process_month_loss_qty,
        SUM(production_qty) AS process_month_production_qty,
        SUM(loss_amount) AS process_month_loss_amount,
        SUM(loss_qty) / NULLIF(SUM(production_qty), 0)
            AS process_month_defect_rate
    FROM defect_loss_fact
    GROUP BY
        `month`,
        process
),
metrics_with_prev AS (
    SELECT
        *,
        LAG(process_month_loss_amount) OVER (
            PARTITION BY process
            ORDER BY `month`
        ) AS prev_loss_amount,
        LAG(process_month_defect_rate) OVER (
            PARTITION BY process
            ORDER BY `month`
        ) AS prev_defect_rate
    FROM process_base
)
SELECT
    `month`,
    process,
    process_month_loss_qty,
    process_month_production_qty,
    process_month_loss_amount,
    process_month_defect_rate,
    (process_month_loss_amount - prev_loss_amount)
        / NULLIF(prev_loss_amount, 0) AS loss_amount_mom,
    (process_month_defect_rate - prev_defect_rate)
        / NULLIF(prev_defect_rate, 0) AS defect_rate_mom
FROM metrics_with_prev;


-- 最终结果检查

-- 产品月指标应为 6000 行
SELECT COUNT(*) AS product_month_row_count
FROM product_month_metrics;

-- 产品月指标应为 0 组重复
SELECT COUNT(*) AS product_month_duplicate_groups
FROM (
    SELECT
        `month`,
        sap_code
    FROM product_month_metrics
    GROUP BY
        `month`,
        sap_code
    HAVING COUNT(*) > 1
) AS duplicated_groups;

-- 工序月指标应为 36 行
SELECT COUNT(*) AS process_month_row_count
FROM process_month_metrics;

-- 工序月指标应为 0 组重复
SELECT COUNT(*) AS process_month_duplicate_groups
FROM (
    SELECT
        `month`,
        process
    FROM process_month_metrics
    GROUP BY
        `month`,
        process
    HAVING COUNT(*) > 1
) AS duplicated_groups;

-- 每个月两类 Top20 都应各有 20 个产品
SELECT
    `month`,
    SUM(is_top20) AS loss_amount_top20_count,
    SUM(is_composite_defect_top20) AS composite_defect_top20_count
FROM product_month_metrics
GROUP BY `month`
ORDER BY `month`;

-- 不良率超出 0 到 1 的记录数应为 0
SELECT COUNT(*) AS invalid_defect_rate_rows
FROM product_month_metrics
WHERE casting_defect_rate NOT BETWEEN 0 AND 1
   OR machining_defect_rate NOT BETWEEN 0 AND 1
   OR polishing_defect_rate NOT BETWEEN 0 AND 1
   OR composite_defect_rate NOT BETWEEN 0 AND 1;

-- 查看每个产品第一月的环比空值情况
SELECT
    `month`,
    SUM(loss_amount_mom IS NULL) AS null_loss_amount_mom_count,
    SUM(composite_defect_rate_mom IS NULL) AS null_composite_defect_rate_mom_count
FROM product_month_metrics
GROUP BY `month`
ORDER BY `month`;

-- 查看最终产品月指标表
SELECT *
FROM product_month_metrics
ORDER BY `month`, loss_amount_rank;

-- 查看最终工序月指标表
SELECT *
FROM process_month_metrics
ORDER BY `month`, process;

-- 工序不良损失金额和不良率月环比
WITH metrics_with_prev AS (
    SELECT
        *,
        LAG(process_month_loss_amount) OVER (
            PARTITION BY process
            ORDER BY `month`
        ) AS prev_loss_amount,

        LAG(process_month_defect_rate) OVER (
            PARTITION BY process
            ORDER BY `month`
        ) AS prev_defect_rate
    FROM process_month_metrics
)
SELECT
    *,
    (process_month_loss_amount - prev_loss_amount)
        / NULLIF(prev_loss_amount, 0) AS loss_amount_mom,

    (process_month_defect_rate - prev_defect_rate)
        / NULLIF(prev_defect_rate, 0) AS defect_rate_mom
FROM metrics_with_prev;


-- ============================================================
-- Tableau CSV 导出查询
-- MySQL 当前禁止 INTO OUTFILE，请分别执行下面三个 SELECT，
-- 再在 Workbench 结果网格中选择“导出记录集”保存为对应 CSV。
-- ============================================================

-- 1. 保存为 tableau_product_month.csv，预期 6000 行
SELECT
    `month`,
    sap_code,
    product_name,
    product_category,
    total_production_qty,
    total_loss_qty,
    total_loss_amount,
    casting_defect_rate,
    machining_defect_rate,
    polishing_defect_rate,
    composite_defect_rate,
    loss_amount_mom,
    composite_defect_rate_mom,
    loss_amount_rank,
    is_top20,
    composite_defect_rate_rank,
    is_composite_defect_top20
FROM product_month_metrics
ORDER BY
    `month`,
    loss_amount_rank;

-- 2. 保存为 tableau_process_month.csv，预期 36 行
SELECT
    `month`,
    process,
    process_month_loss_qty,
    process_month_production_qty,
    process_month_loss_amount,
    process_month_defect_rate,
    loss_amount_mom,
    defect_rate_mom
FROM process_month_metrics
ORDER BY
    `month`,
    process;

-- 3. 保存为 tableau_dq_issues.csv，当前预期 78 行
SELECT
    issue_type,
    `month`,
    sap_code,
    process,
    defect_material_no,
    issue_detail
FROM dq_issues
ORDER BY
    issue_type,
    `month`,
    sap_code,
    process;
