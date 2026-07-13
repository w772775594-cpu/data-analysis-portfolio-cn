USE manufacturing_defect_loss;

SET GLOBAL local_infile = 1;

DROP TABLE IF EXISTS defect_loss_fact;

CREATE TABLE defect_loss_fact (
    `month` VARCHAR(7) NOT NULL,
    sap_code VARCHAR(20) NOT NULL,
    product_name VARCHAR(100),
    product_category VARCHAR(50),
    `process` VARCHAR(20) NOT NULL,
    production_qty INT NOT NULL,
    loss_qty INT NOT NULL,
    unit_price DECIMAL(12, 4) NOT NULL,
    loss_amount DECIMAL(14, 4) NOT NULL,
    has_process_data TINYINT(1) NOT NULL,
    defect_rate DECIMAL(18, 10) NULL
) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

-- 将下方路径替换为本机导出的脱敏/模拟 CSV 绝对路径。
LOAD DATA LOCAL INFILE '/path/to/defect_loss_fact_ascii.csv'
INTO TABLE defect_loss_fact
CHARACTER SET utf8mb4
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 LINES
(
    `month`,
    sap_code,
    product_name,
    product_category,
    `process`,
    production_qty,
    loss_qty,
    unit_price,
    loss_amount,
    @has_process_data,
    @defect_rate
)
SET
    has_process_data = CASE WHEN LOWER(@has_process_data) = 'true' THEN 1 ELSE 0 END,
    defect_rate = NULLIF(@defect_rate, '');

SELECT COUNT(*) AS row_count
FROM defect_loss_fact;

SELECT
    SUM(CASE WHEN loss_qty > production_qty THEN 1 ELSE 0 END) AS loss_qty_gt_production_qty_rows,
    SUM(CASE WHEN loss_qty > 0 AND unit_price = 0 THEN 1 ELSE 0 END) AS loss_qty_gt0_unit_price_eq0_rows,
    SUM(CASE WHEN loss_qty > 0 AND production_qty = 0 THEN 1 ELSE 0 END) AS loss_qty_gt0_production_qty_eq0_rows
FROM defect_loss_fact;
