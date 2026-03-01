# Logging Pipeline Tutorial

This document provides a comprehensive tutorial explaining how logs flow through the OpenTelemetry-compatible logging pipeline in this project, showing transformations at each phase with concrete examples.

## Overview

This project demonstrates three different logging pipelines:

```
                                      ┌─────────────┐
                                ┌────▶│  FluentBit  │────┐
                                │     │  (Lua)      │    │
                                │     └─────────────┘    │
┌─────────┐                     │                        │     ┌────────────┐     ┌─────────┐
│ loggen  │──Method 1 (Zap)─────┤                        ├────▶│ ClickHouse │────▶│ HyperDX │
│  (Go)   │                     │     ┌─────────────┐    │     │  (SQL)     │     │  (UI)   │
│         │──Method 2 (OTLP)────┼────▶│    OTel     │────┤     └────────────┘     └─────────┘
│         │                     │     │  Collector  │    │
│         │──Method 3 (JSON)────┼────▶│  (filelog)  │────┘
└─────────┘                     │     └─────────────┘
         (3 logs per tick)      │           ▲
                                └───────────┘
                                (stdout files)
```

**Measured end-to-end latency** (from log emission to ClickHouse availability):
| Pipeline | Avg Latency | Notes |
|----------|-------------|-------|
| Filelog (Method 3) | ~1s | Fast - direct file reading by Collector |
| OTLP Direct (Method 2) | ~1s | Fast - network-based with SDK batching |
| FluentBit+Lua (Method 1) | ~10s | Slow - file refresh + flush intervals |

Filelog and OTLP have similar latencies (~1s), while FluentBit is ~10x slower due to its refresh/flush intervals.

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

**Source:** `internal/loop/loop.go`

The loggen application emits logs via **three different methods** on each tick for comparison:

#### Method 1: FluentBit+Lua (Zap to stdout)
```go
// internal/loop/loop.go:103-109
l.logger.Info("tick via FluentBit+Lua pipeline",
    zap.Uint64("count", count),
    zap.Int("random_number", randomNum),
    zap.String("random_string", randomStr),
)
```

**Output format:**
```json
{
  "level": "info",
  "ts": 1708272000.123456789,
  "caller": "loop/loop.go:104",
  "msg": "tick via FluentBit+Lua pipeline",
  "count": 42,
  "random_number": 73,
  "random_string": "gamma"
}
```

#### Method 2: OTLP Direct (OTel SDK)
```go
// internal/loop/loop.go:115-130
var record log.Record
record.SetTimestamp(time.Now())
record.SetBody(log.StringValue("tick via OTLP direct to Collector"))
record.SetSeverity(log.SeverityInfo)
record.AddAttributes(
    log.Int64("count", int64(count)),
    log.Int("random_number", randomNum),
    log.String("random_string", randomStr),
)
l.otelLogger.Emit(context.Background(), record)
```

This bypasses stdout entirely and sends logs directly via OTLP to the OTel Collector.

#### Method 3: Collector Filelog (JSON to stdout)
```go
// internal/loop/loop.go:136-150
entry := map[string]any{
    "timestamp":      time.Now().UTC().Format(time.RFC3339Nano),
    "ts":             float64(time.Now().UnixNano()) / 1e9,
    "level":          "info",
    "msg":            "tick via Collector filelog receiver",
    "count":          count,
    "random_number":  randomNum,
    "random_string":  randomStr,
}
json.NewEncoder(os.Stdout).Encode(entry)
```

**Output format:**
```json
{
  "timestamp": "2024-02-18T12:00:00.123456789Z",
  "ts": 1708272000.123456789,
  "level": "info",
  "msg": "tick via Collector filelog receiver",
  "count": 42,
  "random_number": 73,
  "random_string": "gamma"
}
```

**Common field descriptions (all three methods):**

| Field | Type | Description |
|-------|------|-------------|
| `level` | string | Log level (`info`, `debug`, `warn`, `error`, `fatal`) |
| `ts` | float64 | Unix timestamp with nanosecond precision (seconds.nanoseconds) |
| `caller` | string | Source code location (file:line) - Method 1 only |
| `msg`/`body` | string | Log message - unique per method for identification |
| `count` | uint64 | Incrementing tick counter (resets on pod restart) |
| `random_number` | int | Random integer in [0, 100] |
| `random_string` | string | Random selection from: `alpha`, `beta`, `gamma`, `delta`, `epsilon`, `zeta`, `eta`, `theta`, `iota`, `kappa` |

**Message body per method (used for filtering):**
| Method | Body Contains |
|--------|---------------|
| FluentBit+Lua | `"tick via FluentBit+Lua pipeline"` |
| OTLP Direct | `"tick via OTLP direct to Collector"` |
| Collector Filelog | `"tick via Collector filelog receiver"` |

---

### Phase 2: Container Runtime Log Wrapper

**Location:** `/var/log/containers/loggen-*.log`

Kubernetes wraps container stdout in the Docker JSON log format. The container runtime writes each log line as a JSON object:

```json
{
  "log": "{\"level\":\"info\",\"ts\":1708272000.123456789,\"caller\":\"loop/loop.go:104\",\"msg\":\"tick via FluentBit+Lua pipeline\",\"count\":42,\"random_number\":73,\"random_string\":\"gamma\"}\n",
  "stream": "stdout",
  "time": "2024-02-18T12:00:00.123456789Z"
}
```

**Key points:**
- The original JSON log is escaped and stored in the `log` field as a string
- `stream` indicates stdout or stderr (Method 1 and 3 go to stdout)
- `time` is the container runtime's timestamp (RFC3339 format)
- A trailing newline `\n` is included in the `log` field

**Symlink chain:** The container log files use symlinks that must be followed:
```
/var/log/containers/loggen-*.log
    → /var/log/pods/<namespace>_<pod>_<uid>/<container>/*.log
        → /var/lib/docker/containers/<container-id>/<container-id>-json.log
```

This means any log collector reading container logs needs access to all three paths. The OTel Collector filelog receiver requires volume mounts for `/var/lib/docker/containers` to follow these symlinks.

---

### Phase 3: FluentBit Input (tail plugin)

**Source:** `k8s/fluentbit/configmap.yaml:28-38`

FluentBit tails the container log files using the `tail` input plugin:

```ini
[SERVICE]
    Flush        2
    ...

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
| `Flush` | `2` | Flush interval in seconds (production: 2-5 seconds for batch efficiency) |
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

### Phase 4: FluentBit Parsing and Kubernetes Enrichment

**Source:** `k8s/fluentbit/configmap.yaml:41-55`

The parser filter extracts the nested JSON from the `log` field, and the Kubernetes filter enriches records with pod metadata:

```ini
[FILTER]
    Name          parser
    Match         kube.loggen.*
    Key_Name      log
    Parser        json
    Reserve_Data  On

[FILTER]
    Name          kubernetes
    Match         kube.loggen.*
    Merge_Log     On
    Keep_Log      Off
    K8S-Logging.Parser    On
    K8S-Logging.Exclude   On
```

**Kubernetes filter explained:**

| Setting | Value | Purpose |
|---------|-------|---------|
| `Merge_Log` | `On` | Merge parsed log data into the main record |
| `Keep_Log` | `Off` | Remove raw log field after parsing |
| `K8S-Logging.Parser` | `On` | Use pod annotations for custom parsers |
| `K8S-Logging.Exclude` | `On` | Allow pods to exclude themselves from logging |

The Kubernetes filter adds rich metadata including:
- `kubernetes.pod_name` - Pod name
- `kubernetes.namespace_name` - Namespace
- `kubernetes.container_name` - Container name
- `kubernetes.host` - Node name
- `kubernetes.labels` - Pod labels (used for dynamic service name)

**JSON parser definition** (`k8s/fluentbit/configmap.yaml:85-89`):

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
| (from K8s) | `kubernetes.labels.app: "loggen"` |
| (from K8s) | `kubernetes.host: "node-1"` |

---

### Phase 5: FluentBit Transformation (Lua script)

**Source:** `k8s/fluentbit/configmap.yaml:91-199` and `nix/lua/transform.lua`

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

Both the original log timestamp and observation timestamp are captured:

```
Input:  1708272000.123456789 (float seconds since epoch)
Output: Timestamp = "2024-02-18 12:00:00.123456789" (original log time)
        ObservedTimestamp = "2024-02-18 12:00:05.000000000" (FluentBit observation time)
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

**3. Dynamic Service Name**

Service name is extracted dynamically from Kubernetes labels or container name:

```lua
local function get_service_name(record, container)
    -- Try kubernetes labels first (from kubernetes filter)
    if record.kubernetes and record.kubernetes.labels then
        local labels = record.kubernetes.labels
        if labels["app"] then return labels["app"] end
        if labels["app.kubernetes.io/name"] then return labels["app.kubernetes.io/name"] end
        if labels["k8s-app"] then return labels["k8s-app"] end
    end
    -- Fall back to container name
    return container or "unknown"
end
```

**4. Trace Context Extraction**

Trace context is extracted supporting multiple naming conventions:

```lua
local function extract_trace_context(record)
    -- Supports: trace-id, traceId, trace_id (and similar for span)
    local trace_id = record["trace-id"] or record["traceId"] or record["trace_id"] or ""
    local span_id = record["span-id"] or record["spanId"] or record["span_id"] or ""
    local trace_flags = record["trace-flags"] or record["traceFlags"] or record["trace_flags"] or 0
    return trace_id, span_id, tonumber(trace_flags) or 0
end
```

**5. Plain Text Log Support**

For non-JSON logs, severity is detected from text patterns:

```lua
local function detect_severity_from_text(text)
    local lower = text:lower()
    if lower:match("^%[?fatal%]?") or lower:match("^%[?panic%]?") then return "fatal" end
    if lower:match("^%[?error%]?") or lower:match("^%[?err%]?") then return "error" end
    if lower:match("^%[?warn") then return "warn" end
    if lower:match("^%[?debug%]?") then return "debug" end
    if lower:match("^%[?info%]?") then return "info" end
    return nil
end
```

**6. Kubernetes Metadata from Tag**

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

**7. Output OTel Record**

The complete transformed record contains all fields for the ClickHouse schema:

```lua
local otel_record = {
    Timestamp = "2024-02-18 12:00:00.123456789",
    ObservedTimestamp = "2024-02-18 12:00:05.000000000",
    TraceId = "",
    SpanId = "",
    TraceFlags = 0,
    SeverityText = "INFO",
    SeverityNumber = 9,
    ServiceName = "loggen",  -- Dynamically extracted
    Body = "tick",
    ResourceSchemaUrl = "",
    ResourceAttributes = {
        ["service.name"] = "loggen",
        ["service.version"] = "1.0.0",
        ["k8s.namespace.name"] = "otel-demo",
        ["k8s.pod.name"] = "loggen-abc123",
        ["k8s.container.name"] = "loggen",
        ["k8s.node.name"] = "node-1",  -- From Kubernetes filter
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

**Source:** `k8s/fluentbit/configmap.yaml:64-76`

FluentBit sends transformed records to ClickHouse via HTTP with async inserts and gzip compression:

```ini
[OUTPUT]
    Name          http
    Match         *
    Host          clickhouse.otel-demo.svc.cluster.local
    Port          8123
    URI           /?query=INSERT%20INTO%20otel_logs%20FORMAT%20JSONEachRow&async_insert=1
    Format        json_lines
    Json_Date_Key false
    Retry_Limit   5
    Workers       2
    Header        Content-Type application/json
    compress      gzip
```

**Configuration explained:**

| Setting | Value | Purpose |
|---------|-------|---------|
| `Host` | `clickhouse.otel-demo.svc.cluster.local` | ClickHouse service DNS |
| `Port` | `8123` | ClickHouse HTTP port |
| `URI` | `/?query=INSERT INTO otel_logs FORMAT JSONEachRow&async_insert=1` | SQL query with async insert |
| `async_insert` | `1` | Enable async inserts for better throughput |
| `compress` | `gzip` | Gzip compression for reduced network bandwidth |
| `Format` | `json_lines` | One JSON object per line |
| `Workers` | `2` | Parallel HTTP workers |
| `Retry_Limit` | `5` | Retry failed requests up to 5 times |

**HTTP request format:**

```http
POST /?query=INSERT%20INTO%20otel_logs%20FORMAT%20JSONEachRow&async_insert=1 HTTP/1.1
Host: clickhouse.otel-demo.svc.cluster.local:8123
Content-Type: application/json
Content-Encoding: gzip

[gzip compressed payload]
{"Timestamp":"2024-02-18 12:00:00.123456789","ObservedTimestamp":"2024-02-18 12:00:05.000",...}
{"Timestamp":"2024-02-18 12:00:01.234567890","ObservedTimestamp":"2024-02-18 12:00:05.000",...}
```

---

### Phase 6b: OTel Collector Filelog Receiver (Method 3)

**Source:** `k8s/otel-collector/configmap.yaml`

The OTel Collector's filelog receiver reads container log files directly, providing an alternative to FluentBit for log collection:

```yaml
receivers:
  filelog:
    include:
      - /var/log/containers/loggen-*_otel-demo_*.log
    start_at: end
    include_file_path: true
    operators:
      # Parse the container JSON wrapper (from Docker)
      - type: json_parser
        id: container_parser
      # Extract the log field content as body
      - type: move
        from: attributes.log
        to: body
      # Only process stdout logs (filelog method writes to stdout)
      - type: filter
        id: filter_stderr
        expr: 'attributes.stream != "stdout"'
      # Parse our JSON log content to get the msg field
      - type: json_parser
        id: log_parser
        parse_from: body
        on_error: send
      # Set Body to the msg field for consistent display
      - type: move
        id: set_body
        from: attributes.msg
        to: body
```

**Operator Chain Explained:**

| Operator | Purpose |
|----------|---------|
| `json_parser` (container) | Parse Docker's JSON wrapper (`{"log": "...", "stream": "stdout", "time": "..."}`) |
| `move` (log→body) | Move the escaped log content to body for parsing |
| `filter` (stderr) | Drop stderr logs to avoid FluentBit noise |
| `json_parser` (log) | Parse the actual JSON log content |
| `move` (msg→body) | Set the message as the body for HyperDX display |

**Transform Processor for Timestamp:**

The filelog receiver sets `observed_time_unix_nano` but not `time_unix_nano`, which causes logs to appear with epoch 0 timestamps. A transform processor fixes this:

```yaml
processors:
  transform/filelog:
    log_statements:
      - context: log
        statements:
          - set(time_unix_nano, observed_time_unix_nano) where time_unix_nano == 0
          - set(severity_text, "INFO") where attributes["level"] == "info"
          - set(severity_number, 9) where attributes["level"] == "info"
```

**Volume Mounts Required:**

The OTel Collector DaemonSet needs these volume mounts to follow the container log symlink chain:

```yaml
volumeMounts:
  - name: varlog
    mountPath: /var/log
    readOnly: true
  - name: varlogcontainers
    mountPath: /var/log/containers
    readOnly: true
  - name: varlogpods
    mountPath: /var/log/pods
    readOnly: true
  - name: varlibdockercontainers
    mountPath: /var/lib/docker/containers
    readOnly: true
```

**Pipeline Definition:**

```yaml
service:
  pipelines:
    logs/filelog:
      receivers: [filelog]
      processors: [transform/filelog, resource, batch]
      exporters: [clickhouse]
```

---

### Phase 6c: OTel Collector OTLP Receiver (Method 2)

**Source:** `k8s/otel-collector/configmap.yaml`

For OTLP direct logs, the Collector receives logs via gRPC/HTTP and forwards to ClickHouse:

```yaml
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317
      http:
        endpoint: 0.0.0.0:4318

service:
  pipelines:
    logs/otlp:
      receivers: [otlp]
      processors: [resource, batch]
      exporters: [clickhouse]
```

No transform processor is needed for OTLP logs since the SDK sets all fields correctly.

---

### Phase 7: ClickHouse Storage

**Source:** `k8s/clickhouse/configmap.yaml:82-122`

ClickHouse stores logs in the `otel_logs` table with an OTel-compatible schema:

```sql
CREATE TABLE IF NOT EXISTS default.otel_logs (
    -- Timestamp with nanosecond precision
    Timestamp DateTime64(9) CODEC(Delta, ZSTD(1)),
    ObservedTimestamp DateTime64(9) DEFAULT Timestamp CODEC(Delta, ZSTD(1)),

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

    -- Materialized columns for efficient K8s metadata queries
    ContainerName LowCardinality(String) MATERIALIZED ResourceAttributes['k8s.container.name'],
    PodName LowCardinality(String) MATERIALIZED ResourceAttributes['k8s.pod.name'],
    NamespaceName LowCardinality(String) MATERIALIZED ResourceAttributes['k8s.namespace.name'],
    NodeName LowCardinality(String) MATERIALIZED ResourceAttributes['k8s.node.name'],

    -- Custom demo fields (indexed for fast queries)
    RandomNumber Int32 CODEC(ZSTD(1)),
    RandomString LowCardinality(String) CODEC(ZSTD(1)),
    Count UInt64 CODEC(Delta, ZSTD(1)),

    -- Indexes for efficient filtering
    INDEX idx_trace_id TraceId TYPE bloom_filter(0.001) GRANULARITY 1,
    INDEX idx_severity SeverityText TYPE set(25) GRANULARITY 1,
    INDEX idx_service ServiceName TYPE set(100) GRANULARITY 1,
    INDEX idx_container ContainerName TYPE bloom_filter GRANULARITY 4,
    INDEX idx_namespace NamespaceName TYPE set(100) GRANULARITY 1,
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

#### New Columns

| Column | Type | Purpose |
|--------|------|---------|
| `ObservedTimestamp` | `DateTime64(9) DEFAULT Timestamp` | When FluentBit observed the log (defaults to Timestamp for backward compatibility) |
| `ContainerName` | `MATERIALIZED` | Auto-extracted from ResourceAttributes for efficient queries |
| `PodName` | `MATERIALIZED` | Auto-extracted from ResourceAttributes for efficient queries |
| `NamespaceName` | `MATERIALIZED` | Auto-extracted from ResourceAttributes for efficient queries |
| `NodeName` | `MATERIALIZED` | Auto-extracted from ResourceAttributes for efficient queries |

#### Index Explanations

| Index | Type | Purpose |
|-------|------|---------|
| `idx_trace_id` | `bloom_filter(0.001)` | Fast TraceId lookups with 0.1% false positive rate |
| `idx_severity` | `set(25)` | Fast filtering by severity (max 25 unique values) |
| `idx_service` | `set(100)` | Fast filtering by service name (max 100 services) |
| `idx_container` | `bloom_filter` | Fast filtering by container name |
| `idx_namespace` | `set(100)` | Fast filtering by namespace |
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
| `ObservedTimestamp` | `Delta, ZSTD(1)` | Delta encoding for sequential timestamps + compression |
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
| (observation) | - | - | FluentBit timestamp | `ObservedTimestamp: "2024-02-18 12:00:05..."` | ObservedTimestamp | DateTime64(9) |
| level | `level: "info"` | in `log` string | `level: "info"` | `SeverityText: "INFO"`, `SeverityNumber: 9` | SeverityText, SeverityNumber | LowCardinality(String), Int32 |
| message | `msg: "tick"` | in `log` string | `msg: "tick"` | `Body: "tick"` | Body | String |
| caller | `caller: "loop/loop.go:77"` | in `log` string | `caller: "loop/loop.go:77"` | `LogAttributes: {caller: ...}` | LogAttributes | Map(String, String) |
| count | `count: 42` | in `log` string | `count: 42` | `Count: 42` | Count | UInt64 |
| random_number | `random_number: 73` | in `log` string | `random_number: 73` | `RandomNumber: 73` | RandomNumber | Int32 |
| random_string | `random_string: "gamma"` | in `log` string | `random_string: "gamma"` | `RandomString: "gamma"` | RandomString | LowCardinality(String) |
| (from K8s labels) | - | - | `kubernetes.labels.app` | `ServiceName: "loggen"` | ServiceName | LowCardinality(String) |
| (from tag/K8s) | - | - | - | `ResourceAttributes: {k8s.*: ...}` | ResourceAttributes | Map(String, String) |
| (MATERIALIZED) | - | - | - | - | ContainerName | LowCardinality(String) |
| (MATERIALIZED) | - | - | - | - | PodName | LowCardinality(String) |
| (MATERIALIZED) | - | - | - | - | NamespaceName | LowCardinality(String) |
| (MATERIALIZED) | - | - | - | - | NodeName | LowCardinality(String) |
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

### 9. Using MATERIALIZED Columns (Faster)

The MATERIALIZED columns provide faster queries without Map access:

```sql
-- Query using MATERIALIZED columns (preferred)
SELECT
    NamespaceName,
    PodName,
    ContainerName,
    NodeName,
    count() as cnt
FROM otel_logs
GROUP BY NamespaceName, PodName, ContainerName, NodeName
```

### 10. ObservedTimestamp vs Timestamp (Latency Analysis)

Analyze pipeline latency by comparing when logs were generated vs observed:

```sql
SELECT
    avg(toFloat64(ObservedTimestamp - Timestamp)) as avg_latency_seconds,
    max(toFloat64(ObservedTimestamp - Timestamp)) as max_latency_seconds,
    min(toFloat64(ObservedTimestamp - Timestamp)) as min_latency_seconds
FROM otel_logs
WHERE Timestamp > now() - INTERVAL 1 HOUR
```

### 11. Logs by Node

```sql
SELECT
    NodeName,
    count() as log_count,
    countDistinct(PodName) as pod_count
FROM otel_logs
WHERE Timestamp > now() - INTERVAL 1 HOUR
GROUP BY NodeName
ORDER BY log_count DESC
```

### 12. Container Activity Timeline

```sql
SELECT
    toStartOfMinute(Timestamp) as minute,
    ContainerName,
    count() as logs
FROM otel_logs
WHERE Timestamp > now() - INTERVAL 1 HOUR
GROUP BY minute, ContainerName
ORDER BY minute DESC, logs DESC
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

### Measured Latency Summary

| Pipeline | Avg Latency | Min | Max | Notes |
|----------|-------------|-----|-----|-------|
| Collector Filelog | ~1s | ~985ms | ~1012ms | Fast - direct file reading |
| OTLP Direct | ~1s | ~1037ms | ~1051ms | Fast - SDK + collector batching |
| FluentBit+Lua | ~10s | ~872ms | ~58s | High variance due to flush intervals |

**FluentBit latency is dominated by:**
1. **FluentBit refresh interval** (5 seconds) - How often FluentBit checks for new log lines
2. **FluentBit flush interval** (2 seconds) - How often FluentBit sends batched logs to ClickHouse

To reduce FluentBit latency, decrease `Refresh_Interval` and `Flush` in `k8s/fluentbit/configmap.yaml`, but this increases CPU usage.

**For lowest latency:** Use Method 2 (OTLP Direct) or Method 3 (Collector Filelog) - both consistently show ~1s latency.

### Measuring Pipeline Latency with ObservedTimestamp

The `ObservedTimestamp` field allows precise latency measurement:

```sql
-- Analyze latency distribution
SELECT
    quantile(0.5)(toFloat64(ObservedTimestamp - Timestamp)) as p50_latency,
    quantile(0.95)(toFloat64(ObservedTimestamp - Timestamp)) as p95_latency,
    quantile(0.99)(toFloat64(ObservedTimestamp - Timestamp)) as p99_latency
FROM otel_logs
WHERE Timestamp > now() - INTERVAL 1 HOUR
```

---

## Three-Method Logging Comparison

This project demonstrates three different approaches to getting logs into ClickHouse, allowing direct comparison of architecture, complexity, and latency.

### Architecture Overview

```
                                    ┌─────────────┐
                              ┌────►│  FluentBit  │────┐
                              │     │  (Lua)      │    │
                              │     └─────────────┘    │
┌─────────┐                   │                        │     ┌────────────┐
│ loggen  │───Method 1 (Zap)──┤                        ├────►│ ClickHouse │
│         │                   │     ┌─────────────┐    │     │ otel_logs  │
│  tick() │───Method 2 (OTLP)─┼────►│    OTel     │────┤     └────────────┘
│         │                   │     │  Collector  │    │
│         │───Method 3 (JSON)─┼────►│  (filelog)  │────┘
└─────────┘                   │     └─────────────┘
          (3 calls per tick)  │           ▲
                              └───────────┘
                              (stdout files)
```

Each tick of the loggen application emits three logs with identical data but different delivery paths:

### Method 1: FluentBit + Lua (Current Approach)

**Path:** Zap → stdout → FluentBit → Lua → ClickHouse

```
loggen ─(JSON)─► stdout ─(file)─► FluentBit ─(Lua)─► ClickHouse
```

- **Source:** `internal/loop/loop.go:logViaZap()`
- **Config:** `k8s/fluentbit/configmap.yaml`
- **Transform:** `nix/lua/transform.lua`

The application logs using Zap to stdout. FluentBit tails the container log files, parses JSON, enriches with K8s metadata, transforms via Lua to OTel format, and sends to ClickHouse via HTTP.

### Method 2: OTLP Direct (Native OTel)

**Path:** OTel SDK → OTLP → Collector → ClickHouse

```
loggen ─(OTLP/HTTP)─► OTel Collector ─(ClickHouse exporter)─► ClickHouse
```

- **Source:** `internal/loop/loop.go:logViaOTLP()`
- **SDK Init:** `cmd/loggen/main.go:initOTelLogger()`
- **Config:** `k8s/otel-collector/configmap.yaml`

The application uses the OpenTelemetry Go SDK to emit logs directly via OTLP HTTP to the OTel Collector, which exports to ClickHouse. This bypasses file I/O entirely.

### Method 3: Collector Filelog (Hybrid)

**Path:** OTel JSON → stdout → Collector filelog → ClickHouse

```
loggen ─(JSON)─► stdout ─(file)─► OTel Collector ─(filelog)─► ClickHouse
```

- **Source:** `internal/loop/loop.go:logViaFileJSON()`
- **Config:** `k8s/otel-collector/configmap.yaml` (filelog receiver)

The application writes OTel-structured JSON to stdout. The OTel Collector's filelog receiver tails the container logs, parses the JSON, and exports to ClickHouse. This uses OTel-native processing without custom Lua.

### Method Comparison

| Aspect | FluentBit+Lua | OTLP Direct | Collector Filelog |
|--------|---------------|-------------|-------------------|
| **Measured Latency** | ~10s avg | ~1s avg | ~1s avg |
| **Reliability** | File buffer | Network dependent | File buffer |
| **Complexity** | Lua scripting | OTel SDK code | Collector config |
| **K8s Native** | Yes (DaemonSet) | Needs Service | Yes (DaemonSet) |
| **Interoperability** | Custom | Full OTel | Full OTel |
| **Resource Usage** | Lower | Higher (SDK) | Medium |
| **Backpressure** | File-based | Memory-based | File-based |
| **Schema Control** | Full (Lua) | Exporter defaults | Operators |

**Note:** Filelog and OTLP show similar ~1s latency. FluentBit is ~10x slower due to its 5s refresh interval and 2s flush interval.

### Latency Breakdown by Method

#### Method 1: FluentBit+Lua (~10s avg, high variance)
| Stage | Latency | Notes |
|-------|---------|-------|
| Container log write | <1s | Container runtime writes to file |
| FluentBit file refresh | 0-5s | `Refresh_Interval: 5` |
| FluentBit parsing + Lua | <100ms | In-memory processing |
| FluentBit flush | 0-2s | `Flush: 2` |
| Network + ClickHouse | <1s | HTTP POST + async insert |

The high latency and variance is dominated by FluentBit's refresh and flush intervals.

#### Method 2: OTLP Direct (~1s avg)
| Stage | Latency | Notes |
|-------|---------|-------|
| SDK batch timeout | 0-1s | `ExportTimeout: 1s` |
| Network to Collector | <100ms | In-cluster |
| Collector batch | 0-1s | `timeout: 1s` |
| ClickHouse export | <100ms | TCP connection |

Consistent ~1s latency due to SDK and collector batch timeouts.

#### Method 3: Collector Filelog (~1s avg)
| Stage | Latency | Notes |
|-------|---------|-------|
| Container log write | <100ms | Container runtime writes to file |
| Filelog read | <200ms | Continuous file watching |
| Transform + batch | <500ms | Timestamp fix + batching |
| ClickHouse export | <100ms | TCP connection |

Consistent ~1s latency. The filelog receiver uses efficient file watching and the batch processor has a 1s timeout.

### Latency Comparison Query

Compare latency across all three methods using Body content for identification:

```sql
SELECT
    multiIf(
        Body LIKE '%FluentBit%', 'fluentbit',
        Body LIKE '%OTLP direct%', 'otlp',
        Body LIKE '%filelog receiver%', 'filelog',
        'unknown'
    ) AS pipeline,
    count() as log_count,
    avg(dateDiff('millisecond', Timestamp, IngestionTimestamp)) as avg_latency_ms,
    min(dateDiff('millisecond', Timestamp, IngestionTimestamp)) as min_latency_ms,
    max(dateDiff('millisecond', Timestamp, IngestionTimestamp)) as max_latency_ms,
    quantile(0.5)(dateDiff('millisecond', Timestamp, IngestionTimestamp)) as p50_latency_ms,
    quantile(0.95)(dateDiff('millisecond', Timestamp, IngestionTimestamp)) as p95_latency_ms
FROM otel_logs
WHERE Timestamp > now() - INTERVAL 5 MINUTE
GROUP BY pipeline
ORDER BY avg_latency_ms;
```

Example output (from integration tests):
```
┌─pipeline──┬─log_count─┬─avg_latency_ms─┬─min_latency_ms─┬─max_latency_ms─┐
│ filelog   │         7 │           1001 │            985 │           1012 │
│ otlp      │         6 │           1045 │           1037 │           1051 │
│ fluentbit │        17 │          10829 │            872 │          57873 │
└───────────┴───────────┴────────────────┴────────────────┴────────────────┘
```

**Note:** Filelog and OTLP show consistent ~1s latency. FluentBit shows high variance (0.8s - 58s) due to its refresh/flush intervals.

### Verify All Methods

Each method logs a unique message body, making it easy to query by pipeline:

| Pipeline | Body Contains | Example Query |
|----------|---------------|---------------|
| FluentBit+Lua | `FluentBit` | `Body LIKE '%FluentBit%'` |
| OTLP Direct | `OTLP direct` | `Body LIKE '%OTLP direct%'` |
| Collector Filelog | `filelog receiver` | `Body LIKE '%filelog receiver%'` |

```bash
# Check each pipeline is producing logs
kubectl -n otel-demo exec clickhouse-0 -- clickhouse-client --query "
    SELECT count() FROM otel_logs
    WHERE Body LIKE '%FluentBit%'
    AND Timestamp > now() - INTERVAL 1 MINUTE
"
echo "FluentBit pipeline: logs in last minute"

kubectl -n otel-demo exec clickhouse-0 -- clickhouse-client --query "
    SELECT count() FROM otel_logs
    WHERE Body LIKE '%OTLP direct%'
    AND Timestamp > now() - INTERVAL 1 MINUTE
"
echo "OTLP direct pipeline: logs in last minute"

kubectl -n otel-demo exec clickhouse-0 -- clickhouse-client --query "
    SELECT count() FROM otel_logs
    WHERE Body LIKE '%filelog receiver%'
    AND Timestamp > now() - INTERVAL 1 MINUTE
"
echo "Filelog pipeline: logs in last minute"
```

### When to Use Each Method

**Use FluentBit+Lua when:**
- You need custom transformation logic
- You want maximum control over the schema
- You already have FluentBit deployed
- You need to handle non-OTel log formats

**Use OTLP Direct when:**
- Latency is critical
- You control the application code
- You want full OTel semantic conventions
- You need trace/log correlation

**Use Collector Filelog when:**
- You want OTel-native processing
- You can't modify the application to use OTLP
- You want the reliability of file-based collection
- You need a migration path from FluentBit

---

## Key Files Reference

| File | Purpose |
|------|---------|
| `internal/loop/loop.go` | Log generation code with three logging methods (lines 103-150) |
| `cmd/loggen/main.go` | OTel SDK initialization for OTLP direct (Method 2) |
| `k8s/fluentbit/configmap.yaml` | FluentBit configuration for Method 1 (Lua transform) |
| `k8s/otel-collector/configmap.yaml` | OTel Collector config: filelog receiver + OTLP receiver + transform processor |
| `k8s/otel-collector/deployment.yaml` | OTel Collector DaemonSet with volume mounts for `/var/lib/docker/containers` |
| `k8s/otel-collector/service.yaml` | OTLP endpoint Service (ports 4317/4318) |
| `nix/lua/transform.lua` | Lua transform script for Method 1 |
| `k8s/clickhouse/configmap.yaml` | ClickHouse schema with OTel log columns |
| `k8s/hyperdx/deployment.yaml` | HyperDX configuration |
| `nix/verify/integration.nix` | Integration tests verifying all three pipelines with latency comparison |

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

### No filelog logs in ClickHouse (Method 3)

1. **Check volume mounts:** The OTel Collector DaemonSet must have `/var/lib/docker/containers` mounted to follow symlinks
   ```bash
   kubectl -n otel-demo get daemonset otel-collector -o yaml | grep -A5 volumeMounts
   ```

2. **Check collector can read files:**
   ```bash
   kubectl -n otel-demo exec -it $(kubectl -n otel-demo get pods -l app=otel-collector -o name | head -1) -- \
     ls -la /var/log/containers/loggen-*
   ```

3. **Check for JSON parser errors:**
   ```bash
   kubectl -n otel-demo logs -l app=otel-collector --tail=50 | grep -i error
   ```

4. **Verify filter isn't dropping logs:** The filter `expr: 'attributes.stream != "stdout"'` should only drop stderr logs

5. **Check timestamp fix:** If logs have epoch 0 timestamps, the transform processor isn't working:
   ```bash
   kubectl -n otel-demo exec clickhouse-0 -- clickhouse-client --query "
     SELECT Timestamp, Body FROM otel_logs
     WHERE Body LIKE '%filelog%'
     ORDER BY Timestamp DESC LIMIT 5"
   ```

### OTLP logs not arriving (Method 2)

1. **Check service endpoints:**
   ```bash
   kubectl -n otel-demo get endpoints otel-collector
   ```
   If `ENDPOINTS: <none>`, the service selector doesn't match pod labels.

2. **Check collector is listening:**
   ```bash
   kubectl -n otel-demo exec -it $(kubectl -n otel-demo get pods -l app=otel-collector -o name | head -1) -- \
     netstat -tlnp | grep 4317
   ```

3. **Check loggen can reach collector:**
   ```bash
   kubectl -n otel-demo logs -l app=loggen --tail=20 | grep -i otel
   ```

### HyperDX shows no data

1. Verify ClickHouse has records: `nix run .#verify-clickhouse`
2. Check HyperDX can connect to ClickHouse: look at HyperDX pod logs
3. Verify the data source configuration matches the table schema
