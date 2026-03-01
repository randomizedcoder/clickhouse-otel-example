-------------------------------------------------------------------
--
-- OpenTelemetry Logs Migration
--
-- This migration creates OTEL-compliant log tables to replace the existing
-- logs, siden_services_logs, and infrastructure_logs tables.
--
-- Key improvements:
-- 1. Flat Body field for full-text search (fixes HyperDX)
-- 2. Top-level TraceId for distributed tracing
-- 3. Standardized severity levels (SeverityText/SeverityNumber)
-- 4. Optimized indexing for key search patterns
-- 5. OTEL-standard resource and log attributes
--
-- Related: LogsMigrationFinalPlan.md
--
-------------------------------------------------------------------

-- ============================================================================
-- Main OTEL Logs Table
-- ============================================================================
-- All logs flow here first, then separated by materialized views
-- Optimized ORDER BY: ServiceName → ContainerName → NamespaceName → Timestamp

CREATE TABLE IF NOT EXISTS kubernetes.otel_logs ON CLUSTER 'k8s-logs'
(
    -- Timestamps (OTEL Standard)
    `Timestamp` DateTime64(9) CODEC(Delta, ZSTD),
    `ObservedTimestamp` DateTime64(9) CODEC(Delta, ZSTD),

    -- Trace Context (TOP LEVEL for trace correlation)
    `TraceId` String CODEC(ZSTD),
    `SpanId` String CODEC(ZSTD),
    `TraceFlags` UInt32 DEFAULT 0,

    -- Severity (replaces log_level)
    `SeverityText` LowCardinality(String),
    `SeverityNumber` UInt8,

    -- Body - FLAT STRING (fixes full-text search in HyperDX)
    `Body` String CODEC(ZSTD),

    -- OTEL Attributes
    `ResourceAttributes` Map(LowCardinality(String), String) CODEC(ZSTD),
    `LogAttributes` Map(LowCardinality(String), String) CODEC(ZSTD),

    -- Materialized indexed fields for fast querying
    `ServiceName` String MATERIALIZED ResourceAttributes['service.name'],
    `ContainerName` LowCardinality(String) MATERIALIZED ResourceAttributes['k8s.container.name'],
    `PodName` LowCardinality(String) MATERIALIZED ResourceAttributes['k8s.pod.name'],
    `NamespaceName` LowCardinality(String) MATERIALIZED ResourceAttributes['k8s.namespace.name'],
    `NodeName` LowCardinality(String) MATERIALIZED ResourceAttributes['k8s.node.name'],

    -- Service identification for separation logic
    `IsSidenService` UInt8 MATERIALIZED if(ResourceAttributes['siden.service'] != '', 1, 0),

    -- Indexes optimized for search patterns
    INDEX idx_trace_id TraceId TYPE bloom_filter GRANULARITY 1,
    INDEX idx_span_id SpanId TYPE bloom_filter GRANULARITY 1,
    INDEX idx_severity SeverityNumber TYPE minmax GRANULARITY 4,
    INDEX idx_body Body TYPE tokenbf_v1(32768, 3, 0) GRANULARITY 1,
    INDEX idx_service ServiceName TYPE bloom_filter GRANULARITY 4,
    INDEX idx_container ContainerName TYPE bloom_filter GRANULARITY 4
)
ENGINE = ReplicatedMergeTree
PARTITION BY toYYYYMMDD(Timestamp)
ORDER BY (ServiceName, ContainerName, NamespaceName, Timestamp)
TTL toDateTime(Timestamp) + INTERVAL 1 DAY
SETTINGS index_granularity = 8192;

-- ============================================================================
-- Service Logs Table (Siden services - 30 day TTL)
-- ============================================================================

CREATE TABLE IF NOT EXISTS kubernetes.otel_service_logs ON CLUSTER 'k8s-logs'
(
    `Timestamp` DateTime64(9) CODEC(Delta, ZSTD),
    `ObservedTimestamp` DateTime64(9) CODEC(Delta, ZSTD),
    `TraceId` String CODEC(ZSTD),
    `SpanId` String CODEC(ZSTD),
    `TraceFlags` UInt32,
    `SeverityText` LowCardinality(String),
    `SeverityNumber` UInt8,
    `Body` String CODEC(ZSTD),
    `ResourceAttributes` Map(LowCardinality(String), String) CODEC(ZSTD),
    `LogAttributes` Map(LowCardinality(String), String) CODEC(ZSTD),

    -- Materialized indexed fields
    `ServiceName` String MATERIALIZED ResourceAttributes['service.name'],
    `ContainerName` LowCardinality(String) MATERIALIZED ResourceAttributes['k8s.container.name'],
    `PodName` LowCardinality(String) MATERIALIZED ResourceAttributes['k8s.pod.name'],
    `NamespaceName` LowCardinality(String) MATERIALIZED ResourceAttributes['k8s.namespace.name'],
    `NodeName` LowCardinality(String) MATERIALIZED ResourceAttributes['k8s.node.name'],

    -- Indexes for fast querying
    INDEX idx_trace_id TraceId TYPE bloom_filter GRANULARITY 1,
    INDEX idx_body Body TYPE tokenbf_v1(32768, 3, 0) GRANULARITY 1,
    INDEX idx_service ServiceName TYPE bloom_filter GRANULARITY 4,
    INDEX idx_container ContainerName TYPE bloom_filter GRANULARITY 4
)
ENGINE = ReplicatedMergeTree
PARTITION BY toYYYYMMDD(Timestamp)
ORDER BY (ServiceName, ContainerName, NamespaceName, Timestamp)
TTL toDateTime(Timestamp) + INTERVAL 30 DAY
SETTINGS index_granularity = 8192;

-- ============================================================================
-- Infrastructure Logs Table (Third-party services - 7 day TTL)
-- ============================================================================

CREATE TABLE IF NOT EXISTS kubernetes.otel_infrastructure_logs ON CLUSTER 'k8s-logs'
(
    `Timestamp` DateTime64(9) CODEC(Delta, ZSTD),
    `ObservedTimestamp` DateTime64(9) CODEC(Delta, ZSTD),
    `TraceId` String CODEC(ZSTD),
    `SpanId` String CODEC(ZSTD),
    `TraceFlags` UInt32,
    `SeverityText` LowCardinality(String),
    `SeverityNumber` UInt8,
    `Body` String CODEC(ZSTD),
    `ResourceAttributes` Map(LowCardinality(String), String) CODEC(ZSTD),
    `LogAttributes` Map(LowCardinality(String), String) CODEC(ZSTD),

    -- Materialized indexed fields
    `ServiceName` String MATERIALIZED ResourceAttributes['service.name'],
    `ContainerName` LowCardinality(String) MATERIALIZED ResourceAttributes['k8s.container.name'],
    `PodName` LowCardinality(String) MATERIALIZED ResourceAttributes['k8s.pod.name'],
    `NamespaceName` LowCardinality(String) MATERIALIZED ResourceAttributes['k8s.namespace.name'],
    `NodeName` LowCardinality(String) MATERIALIZED ResourceAttributes['k8s.node.name'],

    -- Indexes for trace correlation and full-text search
    INDEX idx_trace_id TraceId TYPE bloom_filter GRANULARITY 1,
    INDEX idx_body Body TYPE tokenbf_v1(32768, 3, 0) GRANULARITY 1
)
ENGINE = ReplicatedMergeTree
PARTITION BY toYYYYMMDD(Timestamp)
ORDER BY (ServiceName, ContainerName, NamespaceName, Timestamp)
TTL toDateTime(Timestamp) + INTERVAL 7 DAY
SETTINGS index_granularity = 8192;

-- ============================================================================
-- Materialized Views for Automatic Separation
-- ============================================================================
-- Logs are automatically routed to service_logs or infrastructure_logs
-- based on the 'siden.service' resource attribute

CREATE MATERIALIZED VIEW IF NOT EXISTS kubernetes.otel_service_logs_mv ON CLUSTER 'k8s-logs'
TO kubernetes.otel_service_logs
AS
SELECT * FROM kubernetes.otel_logs
WHERE IsSidenService = 1;

CREATE MATERIALIZED VIEW IF NOT EXISTS kubernetes.otel_infrastructure_logs_mv ON CLUSTER 'k8s-logs'
TO kubernetes.otel_infrastructure_logs
AS
SELECT * FROM kubernetes.otel_logs
WHERE IsSidenService = 0;

CREATE TABLE IF NOT EXISTS kubernetes_dist.otel_service_logs ON CLUSTER 'k8s-logs' AS kubernetes.otel_service_logs ENGINE = Distributed('k8s-logs', kubernetes, otel_service_logs);

CREATE TABLE IF NOT EXISTS kubernetes_dist.otel_infrastructure_logs ON CLUSTER 'k8s-logs' AS kubernetes.otel_infrastructure_logs ENGINE = Distributed('k8s-logs', kubernetes, otel_infrastructure_logs);
