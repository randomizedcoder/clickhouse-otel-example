-- HyperDX compatible OTel logs schema
-- This schema stores OpenTelemetry log records in a format compatible with HyperDX

CREATE DATABASE IF NOT EXISTS default;

CREATE TABLE IF NOT EXISTS default.otel_logs (
    -- Timestamp with nanosecond precision
    Timestamp DateTime64(9) CODEC(Delta, ZSTD(1)),

    -- Trace context for correlation
    TraceId String CODEC(ZSTD(1)),
    SpanId String CODEC(ZSTD(1)),
    TraceFlags UInt32 CODEC(ZSTD(1)),

    -- Severity information
    SeverityText LowCardinality(String) CODEC(ZSTD(1)),
    SeverityNumber Int32 CODEC(ZSTD(1)),

    -- Service identification
    ServiceName LowCardinality(String) CODEC(ZSTD(1)),

    -- Log message body
    Body String CODEC(ZSTD(1)),

    -- Resource attributes (where the log came from)
    ResourceSchemaUrl String CODEC(ZSTD(1)),
    ResourceAttributes Map(LowCardinality(String), String) CODEC(ZSTD(1)),

    -- Instrumentation scope
    ScopeSchemaUrl String CODEC(ZSTD(1)),
    ScopeName String CODEC(ZSTD(1)),
    ScopeVersion String CODEC(ZSTD(1)),
    ScopeAttributes Map(LowCardinality(String), String) CODEC(ZSTD(1)),

    -- Log-specific attributes
    LogAttributes Map(LowCardinality(String), String) CODEC(ZSTD(1)),

    -- Custom indexed fields for this demo
    -- These enable efficient queries on the random data
    RandomNumber Int32 CODEC(ZSTD(1)),
    RandomString LowCardinality(String) CODEC(ZSTD(1)),
    Count UInt64 CODEC(Delta, ZSTD(1)),

    -- Indexes for common query patterns
    INDEX idx_trace_id TraceId TYPE bloom_filter(0.001) GRANULARITY 1,
    INDEX idx_severity SeverityText TYPE set(25) GRANULARITY 1,
    INDEX idx_service ServiceName TYPE set(100) GRANULARITY 1,
    INDEX idx_random_number RandomNumber TYPE minmax GRANULARITY 1,
    INDEX idx_random_string RandomString TYPE set(10) GRANULARITY 1,
    INDEX idx_body Body TYPE tokenbf_v1(32768, 3, 0) GRANULARITY 1
)
ENGINE = MergeTree()
PARTITION BY toDate(Timestamp)
ORDER BY (ServiceName, Timestamp)
TTL toDateTime(Timestamp) + INTERVAL 7 DAY
SETTINGS
    index_granularity = 8192,
    ttl_only_drop_parts = 1;

-- Materialized view for hourly aggregations
-- Useful for dashboard summaries and trend analysis
CREATE MATERIALIZED VIEW IF NOT EXISTS default.otel_logs_hourly
ENGINE = SummingMergeTree()
PARTITION BY toDate(hour)
ORDER BY (ServiceName, hour, RandomString)
AS SELECT
    toStartOfHour(Timestamp) AS hour,
    ServiceName,
    RandomString,
    count() AS log_count,
    avg(RandomNumber) AS avg_random_number,
    min(RandomNumber) AS min_random_number,
    max(RandomNumber) AS max_random_number
FROM default.otel_logs
GROUP BY hour, ServiceName, RandomString;

-- Example queries for the demo:

-- Count logs by random_string
-- SELECT RandomString, count() AS cnt FROM otel_logs GROUP BY RandomString ORDER BY cnt DESC;

-- Find logs with specific random_number
-- SELECT * FROM otel_logs WHERE RandomNumber = 42 ORDER BY Timestamp DESC LIMIT 100;

-- Time series of log counts per minute
-- SELECT toStartOfMinute(Timestamp) AS minute, count() AS cnt
-- FROM otel_logs
-- GROUP BY minute
-- ORDER BY minute;

-- Logs containing specific random_string in the last hour
-- SELECT * FROM otel_logs
-- WHERE RandomString = 'gamma'
--   AND Timestamp > now() - INTERVAL 1 HOUR
-- ORDER BY Timestamp DESC
-- LIMIT 100;

-- Aggregate stats by severity
-- SELECT SeverityText, count() AS cnt, avg(RandomNumber) AS avg_num
-- FROM otel_logs
-- GROUP BY SeverityText;
