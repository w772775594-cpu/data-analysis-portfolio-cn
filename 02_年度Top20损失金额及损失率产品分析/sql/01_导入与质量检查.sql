USE manufacturing_defect_loss;

-- CSV 导入后先跑这个检查。row_count 应为 18000。
SELECT COUNT(*) AS row_count
FROM defect_loss_fact;

-- 事实表粒度应为 month + sap_code + process，一组最多一行。
SELECT COUNT(*) AS duplicated_month_sap_process_groups
FROM (
    SELECT
        `month`,
        sap_code,
        `process`,
        COUNT(*) AS row_count
    FROM defect_loss_fact
    GROUP BY
        `month`,
        sap_code,
        `process`
    HAVING COUNT(*) > 1
) AS duplicated_groups;

-- 第一批数据质量检查，用于和 notebook 结果对齐。
SELECT
    SUM(CASE WHEN loss_qty > production_qty THEN 1 ELSE 0 END) AS loss_qty_gt_production_qty_rows,
    SUM(CASE WHEN loss_qty > 0 AND unit_price = 0 THEN 1 ELSE 0 END) AS loss_qty_gt0_unit_price_eq0_rows,
    SUM(CASE WHEN loss_qty > 0 AND production_qty = 0 THEN 1 ELSE 0 END) AS loss_qty_gt0_production_qty_eq0_rows
FROM defect_loss_fact;
