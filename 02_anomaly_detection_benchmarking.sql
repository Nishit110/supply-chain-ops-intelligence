-- ============================================================
-- PROJECT 2: Supply Chain Ops Intelligence & Benchmarking
-- File: 02_anomaly_detection_benchmarking.sql
-- Author: Nishit Patel
-- Description: Window functions for cost anomaly detection,
--              carrier benchmarking, and disruption flagging
-- ============================================================


-- ─────────────────────────────────────────────
-- QUERY 1: Month-over-month cost anomaly detection
-- Flags carriers with >10% cost spike vs prior month
-- Uses LAG window function (Redshift-compatible)
-- ─────────────────────────────────────────────
WITH monthly_ops AS (
    SELECT
        dc.carrier_name,
        DATE_TRUNC('month', fs.ship_date)           AS month,
        AVG(fs.shipping_cost)                        AS avg_cost,
        AVG(fs.delivery_days)                        AS avg_delivery_days,
        COUNT(*)                                     AS shipment_volume,
        SUM(CASE WHEN fs.is_late THEN 1 ELSE 0 END) AS late_count,
        ROUND(
            100.0 * SUM(CASE WHEN fs.is_late THEN 1 ELSE 0 END)
            / NULLIF(COUNT(*), 0), 2
        )                                            AS late_rate_pct
    FROM fact_shipments fs
    JOIN dim_carrier dc ON fs.carrier_id = dc.carrier_id
    GROUP BY 1, 2
),
ranked AS (
    SELECT *,
        LAG(avg_cost) OVER (PARTITION BY carrier_name ORDER BY month) AS prev_month_cost,
        ROUND(
            100.0 * (avg_cost - LAG(avg_cost) OVER (PARTITION BY carrier_name ORDER BY month))
            / NULLIF(LAG(avg_cost) OVER (PARTITION BY carrier_name ORDER BY month), 0),
        2) AS cost_change_pct
    FROM monthly_ops
)
SELECT
    carrier_name,
    month,
    ROUND(avg_cost::NUMERIC, 2)         AS avg_cost,
    ROUND(prev_month_cost::NUMERIC, 2)  AS prev_month_cost,
    cost_change_pct,
    late_rate_pct,
    shipment_volume,
    CASE
        WHEN cost_change_pct > 20   THEN 'Critical Spike'
        WHEN cost_change_pct > 10   THEN 'Anomaly — Review'
        WHEN cost_change_pct < -10  THEN 'Significant Drop'
        ELSE 'Normal'
    END AS anomaly_flag
FROM ranked
WHERE cost_change_pct IS NOT NULL
ORDER BY ABS(cost_change_pct) DESC;


-- ─────────────────────────────────────────────
-- QUERY 2: Carrier composite performance score
-- Ranks all carriers by cost + on-time + volume reliability
-- ─────────────────────────────────────────────
WITH carrier_metrics AS (
    SELECT
        dc.carrier_name,
        dc.carrier_type,
        COUNT(*)                                                AS total_shipments,
        ROUND(AVG(fs.shipping_cost)::NUMERIC, 2)               AS avg_cost,
        ROUND(AVG(fs.delivery_days)::NUMERIC, 2)               AS avg_delivery_days,
        ROUND(
            100.0 * SUM(CASE WHEN NOT fs.is_late THEN 1 ELSE 0 END)
            / NULLIF(COUNT(*), 0), 2
        )                                                       AS on_time_rate_pct,
        ROUND(
            100.0 * SUM(CASE WHEN fs.is_damaged THEN 1 ELSE 0 END)
            / NULLIF(COUNT(*), 0), 2
        )                                                       AS damage_rate_pct
    FROM fact_shipments fs
    JOIN dim_carrier dc ON fs.carrier_id = dc.carrier_id
    GROUP BY 1, 2
),
scored AS (
    SELECT *,
        -- Composite score: higher on-time = better, lower cost = better
        ROUND(
            (on_time_rate_pct * 0.5)
            - (damage_rate_pct * 0.3)
            - (PERCENT_RANK() OVER (ORDER BY avg_cost DESC) * 20)
        , 2) AS composite_score
    FROM carrier_metrics
)
SELECT
    carrier_name,
    carrier_type,
    total_shipments,
    avg_cost,
    avg_delivery_days,
    on_time_rate_pct,
    damage_rate_pct,
    composite_score,
    RANK() OVER (ORDER BY composite_score DESC)     AS performance_rank,
    CASE
        WHEN composite_score >= 80 THEN 'Tier 1 — Preferred'
        WHEN composite_score >= 60 THEN 'Tier 2 — Acceptable'
        WHEN composite_score >= 40 THEN 'Tier 3 — Monitor'
        ELSE 'Tier 4 — Review Contract'
    END AS carrier_tier_recommendation
FROM scored
ORDER BY performance_rank;


-- ─────────────────────────────────────────────
-- QUERY 3: Delivery disruption pattern detection
-- Uses LEAD to flag consecutive delay streaks
-- ─────────────────────────────────────────────
WITH daily_delays AS (
    SELECT
        dc.carrier_name,
        fs.ship_date,
        ROUND(AVG(fs.delay_days)::NUMERIC, 1)   AS avg_delay,
        COUNT(*)                                  AS shipments,
        SUM(CASE WHEN fs.is_late THEN 1 ELSE 0 END) AS late_shipments
    FROM fact_shipments fs
    JOIN dim_carrier dc ON fs.carrier_id = dc.carrier_id
    GROUP BY 1, 2
),
with_lead AS (
    SELECT *,
        LEAD(avg_delay) OVER (PARTITION BY carrier_name ORDER BY ship_date) AS next_day_delay,
        LAG(avg_delay)  OVER (PARTITION BY carrier_name ORDER BY ship_date) AS prev_day_delay
    FROM daily_delays
)
SELECT
    carrier_name,
    ship_date,
    avg_delay,
    next_day_delay,
    prev_day_delay,
    CASE
        WHEN avg_delay > 2 AND next_day_delay > 2 AND prev_day_delay > 2
            THEN 'Sustained Disruption — Escalate'
        WHEN avg_delay > 3
            THEN 'Single Day Spike — Monitor'
        ELSE 'Normal'
    END AS disruption_flag
FROM with_lead
WHERE avg_delay > 1
ORDER BY ship_date DESC, avg_delay DESC;


-- ─────────────────────────────────────────────
-- QUERY 4: Regional ops performance heatmap data
-- ─────────────────────────────────────────────
SELECT
    dr.region_name,
    dr.country,
    COUNT(fs.shipment_id)                                   AS total_shipments,
    ROUND(AVG(fs.shipping_cost)::NUMERIC, 2)               AS avg_shipping_cost,
    ROUND(AVG(fs.delivery_days)::NUMERIC, 1)               AS avg_delivery_days,
    ROUND(
        100.0 * SUM(CASE WHEN fs.is_late THEN 1 ELSE 0 END)
        / NULLIF(COUNT(*), 0), 2
    )                                                       AS late_rate_pct,
    ROUND(SUM(fs.total_value)::NUMERIC, 2)                 AS total_shipment_value,
    NTILE(4) OVER (ORDER BY
        100.0 * SUM(CASE WHEN NOT fs.is_late THEN 1 ELSE 0 END)
        / NULLIF(COUNT(*), 0) DESC
    )                                                       AS performance_quartile
FROM fact_shipments fs
JOIN dim_region dr ON fs.region_id = dr.region_id
GROUP BY 1, 2
ORDER BY late_rate_pct DESC;
