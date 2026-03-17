-- ============================================================
-- PROJECT 2: Supply Chain Ops Intelligence & Benchmarking
-- File: 01_schema_setup.sql
-- Author: Nishit Patel
-- Description: Star schema design — Redshift-compatible
--              Fact: shipments | Dims: carrier, region, product
-- ============================================================

-- Drop tables if exist
DROP TABLE IF EXISTS fact_shipments CASCADE;
DROP TABLE IF EXISTS dim_carrier CASCADE;
DROP TABLE IF EXISTS dim_region CASCADE;
DROP TABLE IF EXISTS dim_product CASCADE;
DROP TABLE IF EXISTS dim_date CASCADE;

-- ─────────────────────────────────────────────
-- DIMENSION TABLES
-- ─────────────────────────────────────────────

-- Carrier dimension
CREATE TABLE dim_carrier (
    carrier_id      SERIAL PRIMARY KEY,
    carrier_name    VARCHAR(100) NOT NULL,
    carrier_type    VARCHAR(50),      -- Air, Ground, Sea
    carrier_tier    VARCHAR(20)       -- Premium, Standard, Economy
);

-- Region dimension
CREATE TABLE dim_region (
    region_id       SERIAL PRIMARY KEY,
    country         VARCHAR(100),
    region_name     VARCHAR(100),
    sub_region      VARCHAR(100),
    warehouse_code  VARCHAR(20)
);

-- Product dimension
CREATE TABLE dim_product (
    product_id          SERIAL PRIMARY KEY,
    product_name        VARCHAR(200),
    product_category    VARCHAR(100),
    unit_weight_kg      FLOAT,
    requires_cold_chain BOOLEAN DEFAULT FALSE
);

-- Date dimension (for time-series analysis)
CREATE TABLE dim_date (
    date_id         DATE PRIMARY KEY,
    year            INT,
    quarter         INT,
    month           INT,
    month_name      VARCHAR(20),
    week_of_year    INT,
    day_of_week     VARCHAR(20),
    is_weekend      BOOLEAN
);

-- ─────────────────────────────────────────────
-- FACT TABLE (Redshift-compatible design)
-- Uses DISTKEY on ship_date for time-based queries
-- SORTKEY on carrier_id for join performance
-- ─────────────────────────────────────────────
CREATE TABLE fact_shipments (
    shipment_id         VARCHAR(50) PRIMARY KEY,
    carrier_id          INT REFERENCES dim_carrier(carrier_id),
    region_id           INT REFERENCES dim_region(region_id),
    product_id          INT REFERENCES dim_product(product_id),
    ship_date           DATE REFERENCES dim_date(date_id),
    delivery_date       DATE,

    -- Metrics
    delivery_days       INT,
    estimated_days      INT,
    delay_days          INT GENERATED ALWAYS AS (delivery_days - estimated_days) STORED,
    shipping_cost       FLOAT,
    shipment_weight_kg  FLOAT,
    quantity            INT,
    total_value         FLOAT,

    -- Status flags
    shipment_status     VARCHAR(30),   -- Delivered, Late, Lost, Returned
    is_late             BOOLEAN GENERATED ALWAYS AS (delivery_days > estimated_days) STORED,
    is_damaged          BOOLEAN DEFAULT FALSE,

    -- Redshift comment: DISTKEY(ship_date) SORTKEY(carrier_id)
    created_at          TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Indexes for analytical performance
CREATE INDEX idx_ship_date       ON fact_shipments(ship_date);
CREATE INDEX idx_carrier         ON fact_shipments(carrier_id);
CREATE INDEX idx_status          ON fact_shipments(shipment_status);
CREATE INDEX idx_is_late         ON fact_shipments(is_late);

SELECT 'Star schema created successfully — Redshift-compatible design' AS status;
