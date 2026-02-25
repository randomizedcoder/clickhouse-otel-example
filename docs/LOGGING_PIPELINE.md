# Logging Pipeline Tutorial

This document provides a comprehensive tutorial explaining how logs flow through the OpenTelemetry-compatible logging pipeline in this project, showing transformations at each phase with concrete examples.

## Overview

```
┌─────────┐    ┌───────────┐    ┌────────────┐    ┌─────────┐
│ loggen  │───▶│ FluentBit │───▶│ ClickHouse │───▶│ HyperDX │
│ (Go)    │    │ (Lua)     │    │ (SQL)      │    │ (UI)    │
└─────────┘    └───────────┘    └────────────┘    └─────────┘
   JSON           Parse &           Store &         Query &
   logs          Transform         Index           Visualize
```

**End-to-end latency:** ~6-11 seconds (from log emission to ClickHouse availability)

### Component Roles

| Component | Role | Key Function |
|-----------|------|--------------|
| **loggen** | Log generator | Go app emitting structured JSON logs with zap |
| **FluentBit** | Log collector & transformer | Tails container logs, parses JSON, transforms to OTel format |
| **ClickHouse** | Log storage | Column-oriented database with OTel-compatible schema |
| **HyperDX** | Visualization | Web UI for querying and exploring logs |

---

## Phase-by-Phase Breakdown

### Phase 1: Log Generation (loggen Go app)

**Source:** `internal/loop/loop.go:77-81`

The loggen application uses [zap](https://github.com/uber-go/zap) to emit structured JSON logs at a configurable interval:

```go
l.logger.Info("tick",
    zap.Uint64("count", l.count),
    zap.Int("random_number", randomNum),
    zap.String("random_string", randomStr),
)
```

**Output format:**

```json
{
  "level": "info",
  "ts": 1708272000.123456789,
  "caller": "loop/loop.go:77",
  "msg": "tick",
  "count": 42,
  "random_number": 73,
  "random_string": "gamma"
}
```

**Field descriptions:**

| Field | Type | Description |
|-------|------|-------------|
| `level` | string | Log level (`info`, `debug`, `warn`, `error`, `fatal`) |
| `ts` | float64 | Unix timestamp with nanosecond precision (seconds.nanoseconds) |
| `caller` | string | Source code location (file:line) |
| `msg` | string | Log message |
| `count` | uint64 | Incrementing tick counter (resets on pod restart) |
| `random_number` | int | Random integer in [0, 100] |
| `random_string` | string | Random selection from: `alpha`, `beta`, `gamma`, `delta`, `epsilon`, `zeta`, `eta`, `theta`, `iota`, `kappa` |

---

### Phase 2: Container Runtime Log Wrapper

**Location:** `/var/log/containers/loggen-*.log`

Kubernetes wraps container stdout in the Docker JSON log format. The container runtime writes each log line as a JSON object:

```json
{
  "log": "{\"level\":\"info\",\"ts\":1708272000.123456789,\"caller\":\"loop/loop.go:77\",\"msg\":\"tick\",\"count\":42,\"random_number\":73,\"random_string\":\"gamma\"}\n",
  "stream": "stdout",
  "time": "2024-02-18T12:00:00.123456789Z"
}
```

**Key points:**
- The original JSON log is escaped and stored in the `log` field as a string
- `stream` indicates stdout or stderr
- `time` is the container runtime's timestamp (RFC3339 format)
- A trailing newline `\n` is included in the `log` field

---

### Phase 3: FluentBit Input (tail plugin)

**Source:** `k8s/fluentbit/configmap.yaml:28-38`

FluentBit tails the container log files using the `tail` input plugin:

```ini
[INPUT]
    Name              tail
    Tag               kube.loggen.*
    Path              /var/log/containers/loggen-*.log
    Parser            docker
    Refresh_Interval  5
    Rotate_Wait       30
    Mem_Buf_Limit     10MB
    Skip_Long_Lines   On
    DB                /var/lib/fluent-bit/tail.db
    DB.Sync           Normal
```

**Configuration explained:**

| Setting | Value | Purpose |
|---------|-------|---------|
| `Name` | `tail` | Use the tail input plugin |
| `Tag` | `kube.loggen.*` | Tag for routing (includes filename) |
| `Path` | `/var/log/containers/loggen-*.log` | Only tail loggen container logs |
| `Parser` | `docker` | Parse Docker JSON log format |
| `Refresh_Interval` | `5` | Check for new files every 5 seconds |
| `Mem_Buf_Limit` | `10MB` | Memory buffer limit per file |
| `DB` | `/var/lib/fluent-bit/tail.db` | Track file positions across restarts |

**Docker parser definition** (`k8s/fluentbit/configmap.yaml:68-73`):

```ini
[PARSER]
    Name        docker
    Format      json
    Time_Key    time
    Time_Format %Y-%m-%dT%H:%M:%S.%L
    Time_Keep   On
```

After this phase, the record contains:

```
{
  log: "{\"level\":\"info\",\"ts\":1708272000.123456789,...}\n",
  stream: "stdout",
  time: "2024-02-18T12:00:00.123456789Z"
}
```

---

### Phase 4: FluentBit Parsing (parser filter)

**Source:** `k8s/fluentbit/configmap.yaml:41-46`

The parser filter extracts the nested JSON from the `log` field:

```ini
[FILTER]
    Name          parser
    Match         kube.loggen.*
    Key_Name      log
    Parser        json
    Reserve_Data  On
```

**JSON parser definition** (`k8s/fluentbit/configmap.yaml:75-79`):

```ini
[PARSER]
    Name        json
    Format      json
    Time_Key    ts
    Time_Format %s.%L
```

**Transformation:**

| Before | After |
|--------|-------|
| `log: "{\"level\":\"info\",...}"` | `level: "info"` |
| `stream: "stdout"` | `stream: "stdout"` (preserved) |
| `time: "2024-02-18T..."` | `time: "2024-02-18T..."` (preserved) |
| (nested) | `ts: 1708272000.123456789` |
| (nested) | `msg: "tick"` |
| (nested) | `caller: "loop/loop.go:77"` |
| (nested) | `count: 42` |
| (nested) | `random_number: 73` |
| (nested) | `random_string: "gamma"` |

---

### Phase 5: FluentBit Transformation (Lua script)

**Source:** `k8s/fluentbit/configmap.yaml:81-189` and `nix/lua/transform.lua`

The Lua filter transforms the parsed record into the OTel log format expected by ClickHouse:

```ini
[FILTER]
    Name          lua
    Match         kube.loggen.*
    script        /fluent-bit/scripts/transform.lua
    call          transform_to_otel
```

#### Key Transformations

**1. Severity Mapping**

Zap log levels are mapped to OpenTelemetry severity values:

| Zap Level | OTel SeverityText | OTel SeverityNumber |
|-----------|-------------------|---------------------|
| `debug` | `DEBUG` | 5 |
| `info` | `INFO` | 9 |
| `warn` | `WARN` | 13 |
| `warning` | `WARN` | 13 |
| `error` | `ERROR` | 17 |
| `dpanic` | `FATAL` | 21 |
| `panic` | `FATAL` | 21 |
| `fatal` | `FATAL` | 21 |

**Source:** `nix/lua/transform.lua:8-28`

```lua
local severity_number = {
    debug   = 5,   -- DEBUG
    info    = 9,   -- INFO
    warn    = 13,  -- WARN
    error   = 17,  -- ERROR
    fatal   = 21,  -- FATAL
}
```

**2. Timestamp Conversion**

The zap timestamp (Unix float seconds) is converted to ClickHouse DateTime64(9) format:

```
Input:  1708272000.123456789 (float seconds since epoch)
Output: "2024-02-18 12:00:00.123456789" (DateTime64(9) string)
```

**Source:** `nix/lua/transform.lua:33-42`

```lua
local function format_timestamp(ts)
    local seconds = math.floor(ts)
    local nanos = math.floor((ts - seconds) * 1e9)
    local date_str = os.date("!%Y-%m-%d %H:%M:%S", seconds)
    return string.format("%s.%09d", date_str, nanos)
end
```

**3. Kubernetes Metadata from Tag**

Kubernetes metadata is extracted from the FluentBit tag:

```
Tag: kube.loggen.otel-demo_loggen-abc123_loggen
                 ├─────────┼─────────────┼──────┤
                 │         │             │
                 ▼         ▼             ▼
          namespace      pod        container
          (otel-demo)   (loggen-abc123) (loggen)
```

**Source:** `nix/lua/transform.lua:63-70`

```lua
local function parse_k8s_tag(tag)
    local namespace, pod, container = string.match(
        tag, "kube%.loggen%.([^_]+)_([^_]+)_(.+)"
    )
    return namespace or "unknown", pod or "unknown", container or "unknown"
end
```

**4. Output OTel Record**

The complete transformed record contains all 18 fields for the ClickHouse schema:

```lua
local otel_record = {
    Timestamp = "2024-02-18 12:00:00.123456789",
    TraceId = "",
    SpanId = "",
    TraceFlags = 0,
    SeverityText = "INFO",
    SeverityNumber = 9,
    ServiceName = "loggen",
    Body = "tick",
    ResourceSchemaUrl = "",
    ResourceAttributes = {
        ["service.name"] = "loggen",
        ["service.version"] = "1.0.0",
        ["k8s.namespace.name"] = "otel-demo",
        ["k8s.pod.name"] = "loggen-abc123",
        ["k8s.container.name"] = "loggen",
    },
    ScopeSchemaUrl = "",
    ScopeName = "loggen",
    ScopeVersion = "1.0.0",
    ScopeAttributes = {},
    LogAttributes = {["caller"] = "loop/loop.go:77"},
    RandomNumber = 73,
    RandomString = "gamma",
    Count = 42,
}
```

---

### Phase 6: FluentBit Output (HTTP to ClickHouse)

**Source:** `k8s/fluentbit/configmap.yaml:54-65`

FluentBit sends transformed records to ClickHouse via HTTP:

```ini
[OUTPUT]
    Name          http
    Match         *
    Host          clickhouse.otel-demo.svc.cluster.local
    Port          8123
    URI           /?query=INSERT%20INTO%20otel_logs%20FORMAT%20JSONEachRow
    Format        json_lines
    Json_Date_Key false
    Retry_Limit   5
    Workers       2
    Header        Content-Type application/json
```

**Configuration explained:**

| Setting | Value | Purpose |
|---------|-------|---------|
| `Host` | `clickhouse.otel-demo.svc.cluster.local` | ClickHouse service DNS |
| `Port` | `8123` | ClickHouse HTTP port |
| `URI` | `/?query=INSERT INTO otel_logs FORMAT JSONEachRow` | SQL query with JSON format |
| `Format` | `json_lines` | One JSON object per line |
| `Workers` | `2` | Parallel HTTP workers |
| `Retry_Limit` | `5` | Retry failed requests up to 5 times |

**HTTP request format:**

```http
POST /?query=INSERT%20INTO%20otel_logs%20FORMAT%20JSONEachRow HTTP/1.1
Host: clickhouse.otel-demo.svc.cluster.local:8123
Content-Type: application/json

{"Timestamp":"2024-02-18 12:00:00.123456789","SeverityText":"INFO",...}
{"Timestamp":"2024-02-18 12:00:01.234567890","SeverityText":"INFO",...}
```

---

### Phase 7: ClickHouse Storage

**Source:** `k8s/clickhouse/configmap.yaml:82-113`

ClickHouse stores logs in the `otel_logs` table with an OTel-compatible schema:

```sql
CREATE TABLE IF NOT EXISTS default.otel_logs (
    -- Timestamp with nanosecond precision
    Timestamp DateTime64(9) CODEC(Delta, ZSTD(1)),

    -- Trace context (for correlation with traces)
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

    -- Resource attributes (k8s metadata, service info)
    ResourceSchemaUrl String CODEC(ZSTD(1)),
    ResourceAttributes Map(LowCardinality(String), String) CODEC(ZSTD(1)),

    -- Instrumentation scope
    ScopeSchemaUrl String CODEC(ZSTD(1)),
    ScopeName String CODEC(ZSTD(1)),
    ScopeVersion String CODEC(ZSTD(1)),
    ScopeAttributes Map(LowCardinality(String), String) CODEC(ZSTD(1)),

    -- Log-specific attributes
    LogAttributes Map(LowCardinality(String), String) CODEC(ZSTD(1)),

    -- Custom demo fields (indexed for fast queries)
    RandomNumber Int32 CODEC(ZSTD(1)),
    RandomString LowCardinality(String) CODEC(ZSTD(1)),
    Count UInt64 CODEC(Delta, ZSTD(1)),

    -- Indexes for efficient filtering
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
SETTINGS index_granularity = 8192, ttl_only_drop_parts = 1;
```

#### Index Explanations

| Index | Type | Purpose |
|-------|------|---------|
| `idx_trace_id` | `bloom_filter(0.001)` | Fast TraceId lookups with 0.1% false positive rate |
| `idx_severity` | `set(25)` | Fast filtering by severity (max 25 unique values) |
| `idx_service` | `set(100)` | Fast filtering by service name (max 100 services) |
| `idx_random_number` | `minmax` | Range queries on random_number field |
| `idx_random_string` | `set(10)` | Fast filtering by random_string (10 unique values) |
| `idx_body` | `tokenbf_v1(32768, 3, 0)` | Full-text search on log body |

#### Partitioning & TTL

- **Partitioning:** `PARTITION BY toDate(Timestamp)` - One partition per day
- **TTL:** `INTERVAL 7 DAY` - Logs older than 7 days are automatically deleted
- **Setting:** `ttl_only_drop_parts = 1` - Drop entire partitions when TTL expires (more efficient)

#### Codecs

| Column | Codec | Reason |
|--------|-------|--------|
| `Timestamp` | `Delta, ZSTD(1)` | Delta encoding for sequential timestamps + compression |
| `Count` | `Delta, ZSTD(1)` | Delta encoding for incrementing counter |
| All others | `ZSTD(1)` | General-purpose compression |

---

### Phase 8: HyperDX Visualization

**Source:** `k8s/hyperdx/deployment.yaml:50-51`

HyperDX connects to ClickHouse and maps OTel log fields to its UI columns:

```yaml
DEFAULT_SOURCES: '[{
  "name": "OTel Logs",
  "kind": "log",
  "connection": "Default",
  "from": {
    "databaseName": "default",
    "tableName": "otel_logs"
  },
  "timestampValueExpression": "Timestamp",
  "bodyExpression": "Body",
  "severityTextExpression": "SeverityText",
  "serviceNameExpression": "ServiceName",
  "traceIdExpression": "TraceId",
  "spanIdExpression": "SpanId"
}]'
```

**Field mappings to UI columns:**

| ClickHouse Column | HyperDX UI |
|-------------------|------------|
| `Timestamp` | Timestamp column, time picker |
| `Body` | Log message body |
| `SeverityText` | Severity badge (colored) |
| `ServiceName` | Service filter |
| `TraceId` | Trace correlation link |
| `SpanId` | Span correlation link |

---

## Complete Field Transformation Matrix

This table shows how a log record transforms at each pipeline phase:

| Original Field | Phase 1 (loggen) | Phase 2 (Docker) | Phase 4 (Parser) | Phase 5 (Lua) | ClickHouse Column | ClickHouse Type |
|----------------|------------------|------------------|------------------|---------------|-------------------|-----------------|
| timestamp | `ts: 1708272000.123` | in `log` string | `ts: 1708272000.123` | `Timestamp: "2024-02-18 12:00:00.123..."` | Timestamp | DateTime64(9) |
| level | `level: "info"` | in `log` string | `level: "info"` | `SeverityText: "INFO"`, `SeverityNumber: 9` | SeverityText, SeverityNumber | LowCardinality(String), Int32 |
| message | `msg: "tick"` | in `log` string | `msg: "tick"` | `Body: "tick"` | Body | String |
| caller | `caller: "loop/loop.go:77"` | in `log` string | `caller: "loop/loop.go:77"` | `LogAttributes: {caller: ...}` | LogAttributes | Map(String, String) |
| count | `count: 42` | in `log` string | `count: 42` | `Count: 42` | Count | UInt64 |
| random_number | `random_number: 73` | in `log` string | `random_number: 73` | `RandomNumber: 73` | RandomNumber | Int32 |
| random_string | `random_string: "gamma"` | in `log` string | `random_string: "gamma"` | `RandomString: "gamma"` | RandomString | LowCardinality(String) |
| (from tag) | - | - | - | `ServiceName: "loggen"` | ServiceName | LowCardinality(String) |
| (from tag) | - | - | - | `ResourceAttributes: {k8s.namespace.name: ...}` | ResourceAttributes | Map(String, String) |
| stream | - | `stream: "stdout"` | `stream: "stdout"` | (dropped) | - | - |
| container time | - | `time: "2024-02-18T..."` | `time: "2024-02-18T..."` | (dropped, use ts) | - | - |

---

## Example Queries and Results

### 1. Count Total Records

```sql
SELECT count() FROM otel_logs
```

**Sample output:**
```
┌─count()─┐
│    1847 │
└─────────┘
```

### 2. Recent Logs

```sql
SELECT
    Timestamp,
    SeverityText,
    Body,
    RandomNumber,
    RandomString
FROM otel_logs
ORDER BY Timestamp DESC
LIMIT 10
```

**Sample output:**
```
┌───────────────────────────────Timestamp─┬─SeverityText─┬─Body─┬─RandomNumber─┬─RandomString─┐
│ 2024-02-18 12:00:10.123456789           │ INFO         │ tick │           42 │ gamma        │
│ 2024-02-18 12:00:09.123456789           │ INFO         │ tick │           17 │ alpha        │
│ 2024-02-18 12:00:08.123456789           │ INFO         │ tick │           89 │ beta         │
└─────────────────────────────────────────┴──────────────┴──────┴──────────────┴──────────────┘
```

### 3. Group by Severity

```sql
SELECT
    SeverityText,
    count() as cnt
FROM otel_logs
GROUP BY SeverityText
ORDER BY cnt DESC
```

**Sample output:**
```
┌─SeverityText─┬──cnt─┐
│ INFO         │ 1845 │
│ DEBUG        │    2 │
└──────────────┴──────┘
```

### 4. Time Series (per minute)

```sql
SELECT
    toStartOfMinute(Timestamp) as minute,
    count() as logs_per_minute
FROM otel_logs
GROUP BY minute
ORDER BY minute DESC
LIMIT 10
```

**Sample output:**
```
┌──────────────minute─┬─logs_per_minute─┐
│ 2024-02-18 12:05:00 │              60 │
│ 2024-02-18 12:04:00 │              60 │
│ 2024-02-18 12:03:00 │              60 │
└─────────────────────┴─────────────────┘
```

### 5. Filter by RandomString

```sql
SELECT
    Timestamp,
    Body,
    RandomNumber,
    Count
FROM otel_logs
WHERE RandomString = 'gamma'
ORDER BY Timestamp DESC
LIMIT 10
```

### 6. Latency Measurement

Measure how old the most recent logs are (time since emission):

```sql
SELECT
    toFloat64(now64(3) - Timestamp) as age_seconds,
    Timestamp,
    Count
FROM otel_logs
WHERE Timestamp > now() - INTERVAL 60 SECOND
ORDER BY Timestamp DESC
LIMIT 10
```

**Sample output:**
```
┌─age_seconds─┬───────────────────────────────Timestamp─┬─Count─┐
│       6.234 │ 2024-02-18 12:00:10.123456789           │   847 │
│       7.234 │ 2024-02-18 12:00:09.123456789           │   846 │
│       8.234 │ 2024-02-18 12:00:08.123456789           │   845 │
└─────────────┴─────────────────────────────────────────┴───────┘
```

### 7. Distribution of RandomNumber

```sql
SELECT
    floor(RandomNumber / 10) * 10 as bucket,
    count() as cnt,
    bar(cnt, 0, 500, 20) as histogram
FROM otel_logs
GROUP BY bucket
ORDER BY bucket
```

### 8. Kubernetes Metadata from ResourceAttributes

```sql
SELECT
    ResourceAttributes['k8s.namespace.name'] as namespace,
    ResourceAttributes['k8s.pod.name'] as pod,
    count() as cnt
FROM otel_logs
GROUP BY namespace, pod
```

---

## Verification and Latency Measurement

### Verification Commands

Verify each pipeline stage is working correctly:

```bash
# Verify log generator is running and producing valid JSON
nix run .#verify-loggen

# Verify FluentBit is collecting and processing logs
nix run .#verify-fluentbit

# Verify FluentBit is successfully sending to ClickHouse
nix run .#verify-fluentbit-output

# Verify ClickHouse has the schema and is receiving logs
nix run .#verify-clickhouse

# Verify HyperDX is running and accessible
nix run .#verify-hyperdx

# Run all verifications in sequence
nix run .#verify-pipeline
```

### Latency Measurement Commands

```bash
# Passive measurement: analyze age of recent logs
nix run .#measure-latency

# Active measurement: wait for new logs and measure detection time
nix run .#measure-latency-active
```

### Expected Latency Breakdown

| Stage | Latency | Notes |
|-------|---------|-------|
| Container log write | <1s | Container runtime writes to file |
| FluentBit file refresh | 0-5s | `Refresh_Interval: 5` in config |
| FluentBit parsing + Lua | <100ms | In-memory processing |
| FluentBit flush | 0-1s | `Flush: 1` in config |
| Network + ClickHouse insert | <1s | HTTP POST + MergeTree insert |
| **Total** | **6-11 seconds** | Worst case with unlucky timing |

The latency is dominated by:
1. **FluentBit refresh interval** (5 seconds) - How often FluentBit checks for new log lines
2. **FluentBit flush interval** (1 second) - How often FluentBit sends batched logs to ClickHouse

To reduce latency, you can decrease `Refresh_Interval` in `k8s/fluentbit/configmap.yaml`, but this increases CPU usage.

---

## Key Files Reference

| File | Purpose |
|------|---------|
| `internal/loop/loop.go` | Log generation code (tick function at line 77) |
| `k8s/fluentbit/configmap.yaml` | FluentBit configuration (inputs, filters, outputs, parsers, Lua script) |
| `nix/lua/transform.lua` | Standalone Lua transform script (same as embedded in ConfigMap) |
| `k8s/clickhouse/configmap.yaml` | ClickHouse schema (init.sql with CREATE TABLE) |
| `k8s/hyperdx/deployment.yaml` | HyperDX configuration (data source mappings) |
| `nix/verify/positive.nix` | Verification scripts for each pipeline stage |
| `nix/verify/latency.nix` | Latency measurement scripts |

---

## Troubleshooting

### No logs in ClickHouse

1. Check loggen is running: `nix run .#verify-loggen`
2. Check FluentBit is processing: `kubectl -n otel-demo logs -l app=fluentbit --tail=20`
3. Check for HTTP errors in FluentBit logs: look for `HTTP status=4xx` or `HTTP status=5xx`

### High latency (>30 seconds)

1. Check FluentBit isn't backpressured: look for `[warn] [output:http:...] could not flush` messages
2. Verify ClickHouse is responsive: `kubectl -n otel-demo exec -it clickhouse-0 -- clickhouse-client --query "SELECT 1"`
3. Check memory limits: FluentBit `Mem_Buf_Limit: 10MB` may need increasing

### Lua transformation errors

1. Check FluentBit logs for Lua errors: `kubectl -n otel-demo logs -l app=fluentbit | grep -i lua`
2. Test the Lua script locally with sample data
3. Verify the input JSON format matches expected structure

### HyperDX shows no data

1. Verify ClickHouse has records: `nix run .#verify-clickhouse`
2. Check HyperDX can connect to ClickHouse: look at HyperDX pod logs
3. Verify the data source configuration matches the table schema
