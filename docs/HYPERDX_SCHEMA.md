# HyperDX ClickHouse Schema Reference

This document describes the ClickHouse schema that HyperDX expects for OpenTelemetry data.

## Overview

HyperDX queries ClickHouse tables with specific column names and types. The schema must match
HyperDX's expectations for the UI to properly display logs, traces, and metrics.

## OTEL Logs Table (`otel_logs`)

### Required Columns

| Column | Type | Description |
|--------|------|-------------|
| `Timestamp` | DateTime64(9) | Log timestamp with nanosecond precision |
| `TimestampTime` | DateTime | **CRITICAL**: DateTime version of Timestamp, used for partitioning and queries |
| `TraceId` | String | W3C trace ID for correlation |
| `SpanId` | String | W3C span ID for correlation |
| `TraceFlags` | UInt8 | W3C trace flags |
| `SeverityText` | LowCardinality(String) | Log level (INFO, WARN, ERROR, etc.) |
| `SeverityNumber` | UInt8 | Numeric severity (1-24) |
| `ServiceName` | LowCardinality(String) | Service that emitted the log |
| `Body` | String | Log message content |
| `ResourceSchemaUrl` | LowCardinality(String) | Schema URL for resource attributes |
| `ResourceAttributes` | Map(LowCardinality(String), String) | Resource-level attributes (k8s metadata, etc.) |
| `ScopeSchemaUrl` | LowCardinality(String) | Schema URL for scope attributes |
| `ScopeName` | String | Instrumentation scope name |
| `ScopeVersion` | LowCardinality(String) | Instrumentation scope version |
| `ScopeAttributes` | Map(LowCardinality(String), String) | Scope-level attributes |
| `LogAttributes` | Map(LowCardinality(String), String) | Log-specific attributes |

### Why `TimestampTime` is Critical

HyperDX uses `TimestampTime` for:
1. **Partitioning**: `PARTITION BY toDate(TimestampTime)`
2. **Primary Key**: `PRIMARY KEY (ServiceName, TimestampTime)`
3. **Time-based queries**: The UI queries filter on this column
4. **TTL**: `TTL TimestampTime + INTERVAL N DAY`

Without `TimestampTime`, the histogram may show data but the results table will show "No results found".

### HyperDX Materialized Columns

HyperDX creates materialized columns for common Kubernetes attributes with the `__hdx_materialized_` prefix:

```sql
`__hdx_materialized_k8s.cluster.name` LowCardinality(String) MATERIALIZED ResourceAttributes['k8s.cluster.name']
`__hdx_materialized_k8s.container.name` LowCardinality(String) MATERIALIZED ResourceAttributes['k8s.container.name']
`__hdx_materialized_k8s.deployment.name` LowCardinality(String) MATERIALIZED ResourceAttributes['k8s.deployment.name']
`__hdx_materialized_k8s.namespace.name` LowCardinality(String) MATERIALIZED ResourceAttributes['k8s.namespace.name']
`__hdx_materialized_k8s.node.name` LowCardinality(String) MATERIALIZED ResourceAttributes['k8s.node.name']
`__hdx_materialized_k8s.pod.name` LowCardinality(String) MATERIALIZED ResourceAttributes['k8s.pod.name']
`__hdx_materialized_k8s.pod.uid` LowCardinality(String) MATERIALIZED ResourceAttributes['k8s.pod.uid']
`__hdx_materialized_deployment.environment.name` LowCardinality(String) MATERIALIZED ResourceAttributes['deployment.environment.name']
```

### Recommended Indexes

```sql
INDEX idx_trace_id TraceId TYPE bloom_filter(0.001) GRANULARITY 1,
INDEX idx_res_attr_key mapKeys(ResourceAttributes) TYPE bloom_filter(0.01) GRANULARITY 1,
INDEX idx_res_attr_value mapValues(ResourceAttributes) TYPE bloom_filter(0.01) GRANULARITY 1,
INDEX idx_scope_attr_key mapKeys(ScopeAttributes) TYPE bloom_filter(0.01) GRANULARITY 1,
INDEX idx_scope_attr_value mapValues(ScopeAttributes) TYPE bloom_filter(0.01) GRANULARITY 1,
INDEX idx_log_attr_key mapKeys(LogAttributes) TYPE bloom_filter(0.01) GRANULARITY 1,
INDEX idx_log_attr_value mapValues(LogAttributes) TYPE bloom_filter(0.01) GRANULARITY 1,
INDEX idx_lower_body lower(Body) TYPE tokenbf_v1(32768, 3, 0) GRANULARITY 8
```

### Complete Table Definition

```sql
CREATE TABLE IF NOT EXISTS otel_logs (
    Timestamp DateTime64(9) CODEC(Delta(8), ZSTD(1)),
    TimestampTime DateTime DEFAULT toDateTime(Timestamp),
    TraceId String CODEC(ZSTD(1)),
    SpanId String CODEC(ZSTD(1)),
    TraceFlags UInt8,
    SeverityText LowCardinality(String) CODEC(ZSTD(1)),
    SeverityNumber UInt8,
    ServiceName LowCardinality(String) CODEC(ZSTD(1)),
    Body String CODEC(ZSTD(1)),
    ResourceSchemaUrl LowCardinality(String) CODEC(ZSTD(1)),
    ResourceAttributes Map(LowCardinality(String), String) CODEC(ZSTD(1)),
    ScopeSchemaUrl LowCardinality(String) CODEC(ZSTD(1)),
    ScopeName String CODEC(ZSTD(1)),
    ScopeVersion LowCardinality(String) CODEC(ZSTD(1)),
    ScopeAttributes Map(LowCardinality(String), String) CODEC(ZSTD(1)),
    LogAttributes Map(LowCardinality(String), String) CODEC(ZSTD(1)),
    -- HyperDX materialized columns
    `__hdx_materialized_k8s.container.name` LowCardinality(String) MATERIALIZED ResourceAttributes['k8s.container.name'] CODEC(ZSTD(1)),
    `__hdx_materialized_k8s.namespace.name` LowCardinality(String) MATERIALIZED ResourceAttributes['k8s.namespace.name'] CODEC(ZSTD(1)),
    `__hdx_materialized_k8s.node.name` LowCardinality(String) MATERIALIZED ResourceAttributes['k8s.node.name'] CODEC(ZSTD(1)),
    `__hdx_materialized_k8s.pod.name` LowCardinality(String) MATERIALIZED ResourceAttributes['k8s.pod.name'] CODEC(ZSTD(1)),
    -- Indexes
    INDEX idx_trace_id TraceId TYPE bloom_filter(0.001) GRANULARITY 1,
    INDEX idx_res_attr_key mapKeys(ResourceAttributes) TYPE bloom_filter(0.01) GRANULARITY 1,
    INDEX idx_res_attr_value mapValues(ResourceAttributes) TYPE bloom_filter(0.01) GRANULARITY 1,
    INDEX idx_log_attr_key mapKeys(LogAttributes) TYPE bloom_filter(0.01) GRANULARITY 1,
    INDEX idx_log_attr_value mapValues(LogAttributes) TYPE bloom_filter(0.01) GRANULARITY 1,
    INDEX idx_lower_body lower(Body) TYPE tokenbf_v1(32768, 3, 0) GRANULARITY 8
)
ENGINE = MergeTree
PARTITION BY toDate(TimestampTime)
PRIMARY KEY (ServiceName, TimestampTime)
ORDER BY (ServiceName, TimestampTime, Timestamp)
TTL TimestampTime + INTERVAL 7 DAY
SETTINGS index_granularity = 8192, ttl_only_drop_parts = 1;
```

## Data Source Configuration

When HyperDX auto-detects an OTEL log schema, it checks for these columns:

```typescript
const isOtelLogSchema = hasAllColumns(columns, [
  'Timestamp', 'Body', 'SeverityText', 'TraceId', 'SpanId',
  'ServiceName', 'LogAttributes', 'ResourceAttributes',
]);
```

### Default Table Select Expression

For OTEL logs, HyperDX uses:
```sql
SELECT Timestamp, ServiceName as service, SeverityText as level, Body
```

### Timestamp Expressions

- `timestampValueExpression`: `TimestampTime` (used for filtering)
- `displayedTimestampValueExpression`: `Timestamp` (shown to user with full precision)

## Common Issues

### "No results found" with data in histogram

**Cause**: Missing `TimestampTime` column or incorrect types.

**Solution**: Ensure the table has `TimestampTime DateTime DEFAULT toDateTime(Timestamp)`.

### Materialized columns not working

**Cause**: K8s metadata not in `ResourceAttributes` map, or wrong column name prefix.

**Solution**:
1. Ensure FluentBit/OTel Collector puts K8s metadata in `ResourceAttributes`
2. Use `__hdx_materialized_` prefix for materialized columns

### Type mismatches

**Cause**: Using wrong types (e.g., Int32 instead of UInt8 for SeverityNumber).

**Solution**: Match the exact types from HyperDX's schema.

## References

- [HyperDX otel_logs schema](https://github.com/hyperdxio/hyperdx/blob/main/docker/otel-collector/schema/seed/00002_otel_logs.sql)
- [HyperDX source configuration](https://github.com/hyperdxio/hyperdx/blob/main/packages/app/src/source.ts)
