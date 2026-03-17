-- ============================================================
-- PROJECT 2: Supply Chain Ops Intelligence & Benchmarking
-- File: 03_standardized_sop_reporting.sql
-- Author: Nishit Patel
-- Description: 3-tier SOP reporting — Daily / Weekly / Monthly
--              Executive summary layer on top of ops data
-- ============================================================


-- ─────────────────────────────────────────────
-- TIER 1: DAILY OPS SNAPSHOT
-- Run every morning — ops team consumption
-- ─────────────────────────────────────────────
CREATE OR REPLACE VIEW vw_daily_ops_snapshot AS
SELECT
    fs.ship_date                                                        AS report_date,
    dc.carrier_name,
    COUNT(fs.shipment_id)                                               AS shipments_today,
    SUM(CASE WHEN fs.is_late THEN 1 ELSE 0 END)                        AS late_count,
    ROUND(
        100.0 * SUM(CASE WHEN fs.is_late THEN 1 ELSE 0 END)
        / NULLIF(COUNT(*), 0), 2
    )                                                                    AS late_rate_pct,
    ROUND(AVG(fs.shipping_cost)::NUMERIC, 2)                           AS avg_cost,
    ROUND(SUM(fs.total_value)::NUMERIC, 2)                             AS total_value_shipped
FROM fact_shipments fs
JOIN dim_carrier dc ON fs.carrier_id = dc.carrier_id
WHERE fs.ship_date = CURRENT_DATE - INTERVAL '1 day'
GROUP BY 1, 2
ORDER BY late_rate_pct DESC;


-- ─────────────────────────────────────────────
-- TIER 2: WEEKLY TREND REPORT
-- Run every Monday — team lead consumption
-- ─────────────────────────────────────────────
CREATE OR REPLACE VIEW vw_weekly_trend_report AS
WITH weekly_data AS (
    SELECT
        DATE_TRUNC('week', fs.ship_date)                                AS week_start,
        COUNT(fs.shipment_id)                                           AS total_shipments,
        ROUND(AVG(fs.shipping_cost)::NUMERIC, 2)                       AS avg_cost,
        ROUND(AVG(fs.delivery_days)::NUMERIC, 1)                       AS avg_delivery_days,
        ROUND(
            100.0 * SUM(CASE WHEN fs.is_late THEN 1 ELSE 0 END)
            / NULLIF(COUNT(*), 0), 2
        )                                                                AS late_rate_pct,
        ROUND(SUM(fs.total_value)::NUMERIC, 2)                         AS total_value
    FROM fact_shipments fs
    GROUP BY 1
)
SELECT
    week_start,
    total_shipments,
    avg_cost,
    avg_delivery_days,
    late_rate_pct,
    total_value,
    -- Week-over-week comparisons
    LAG(total_shipments) OVER (ORDER BY week_start)                     AS prev_week_shipments,
    LAG(late_rate_pct)   OVER (ORDER BY week_start)                     AS prev_week_late_rate,
    ROUND(late_rate_pct - LAG(late_rate_pct) OVER (ORDER BY week_start), 2) AS late_rate_delta,
    -- Running total
    SUM(total_shipments) OVER (ORDER BY week_start
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)              AS ytd_shipments
FROM weekly_data
ORDER BY week_start DESC;


-- ─────────────────────────────────────────────
-- TIER 3: MONTHLY EXECUTIVE SUMMARY
-- Run on 1st of each month — leadership consumption
-- ─────────────────────────────────────────────
CREATE OR REPLACE VIEW vw_monthly_executive_summary AS
WITH monthly AS (
    SELECT
        DATE_TRUNC('month', fs.ship_date)                               AS month,
        COUNT(fs.shipment_id)                                           AS total_shipments,
        COUNT(DISTINCT fs.carrier_id)                                   AS active_carriers,
        COUNT(DISTINCT fs.region_id)                                    AS active_regions,
        ROUND(AVG(fs.shipping_cost)::NUMERIC, 2)                       AS avg_shipping_cost,
        ROUND(SUM(fs.total_value)::NUMERIC, 2)                         AS total_shipment_value,
        ROUND(
            100.0 * SUM(CASE WHEN NOT fs.is_late THEN 1 ELSE 0 END)
            / NULLIF(COUNT(*), 0), 2
        )                                                                AS on_time_rate_pct,
        ROUND(
            100.0 * SUM(CASE WHEN fs.is_damaged THEN 1 ELSE 0 END)
            / NULLIF(COUNT(*), 0), 2
        )                                                                AS damage_rate_pct
    FROM fact_shipments fs
    GROUP BY 1
)
SELECT
    month,
    total_shipments,
    active_carriers,
    active_regions,
    avg_shipping_cost,
    total_shipment_value,
    on_time_rate_pct,
    damage_rate_pct,
    -- MoM growth
    ROUND(
        100.0 * (total_shipment_value
            - LAG(total_shipment_value) OVER (ORDER BY month))
        / NULLIF(LAG(total_shipment_value) OVER (ORDER BY month), 0),
    2) AS value_growth_pct,
    -- Health score (composite for exec view)
    ROUND(
        (on_time_rate_pct * 0.6)
        - (damage_rate_pct * 0.4),
    2) AS ops_health_score
FROM monthly
ORDER BY month DESC;


-- ─────────────────────────────────────────────
-- PERFORMANCE EVALUATION METRICS STANDARD
-- Standardized SOP thresholds for all ops teams
-- ─────────────────────────────────────────────
CREATE OR REPLACE VIEW vw_sop_performance_evaluation AS
SELECT
    carrier_name,
    on_time_rate_pct,
    CASE
        WHEN on_time_rate_pct >= 95 THEN 'Exceeds Standard'
        WHEN on_time_rate_pct >= 85 THEN 'Meets Standard'
        WHEN on_time_rate_pct >= 70 THEN 'Below Standard'
        ELSE 'Non-Compliant — Action Required'
    END AS on_time_evaluation,

    avg_cost,
    CASE
        WHEN avg_cost <= 50  THEN 'Cost Efficient'
        WHEN avg_cost <= 100 THEN 'Acceptable'
        ELSE 'Cost Review Required'
    END AS cost_evaluation,

    damage_rate_pct,
    CASE
        WHEN damage_rate_pct < 1 THEN 'Excellent'
        WHEN damage_rate_pct < 3 THEN 'Acceptable'
        ELSE 'Critical — Investigate'
    END AS damage_evaluation

FROM (
    SELECT
        dc.carrier_name,
        ROUND(AVG(fs.shipping_cost)::NUMERIC, 2)    AS avg_cost,
        ROUND(
            100.0 * SUM(CASE WHEN NOT fs.is_late THEN 1 ELSE 0 END)
            / NULLIF(COUNT(*), 0), 2
        )                                            AS on_time_rate_pct,
        ROUND(
            100.0 * SUM(CASE WHEN fs.is_damaged THEN 1 ELSE 0 END)
            / NULLIF(COUNT(*), 0), 2
        )                                            AS damage_rate_pct
    FROM fact_shipments fs
    JOIN dim_carrier dc ON fs.carrier_id = dc.carrier_id
    GROUP BY 1
) carrier_summary
ORDER BY on_time_rate_pct DESC;
