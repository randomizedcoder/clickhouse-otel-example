# Status Report - March 4th, 2026

## Overview

Successfully migrated from standalone HyperDX to ClickStack (ClickHouse's official observability stack) and added a standalone OTel Collector for OTLP ingestion. Two of three logging pipelines are now operational.

## What's Working

### Logging Pipelines

| Method | Pipeline | Status | Latency |
|--------|----------|--------|---------|
| FluentBit+Lua | Zap → stdout → FluentBit tail → Lua transform → ClickHouse | ✅ Working | ~1-2s |
| OTLP Direct | OTel SDK → otel-collector:4318 → ClickHouse | ✅ Working | ~1s |
| Collector Filelog | JSON → stdout → OTel Collector filelog receiver → ClickHouse | ✅ Working | ~1s |

### Services

| Service | Container | Status | Notes |
|---------|-----------|--------|-------|
| ClickHouse | otel-clickhouse | ✅ Running | External ClickHouse 25.x (not ClickStack's bundled one) |
| ClickStack | otel-clickstack | ✅ Running | HyperDX UI only - bundled collector disabled |
| OTel Collector | otel-collector | ✅ Running | Standalone collector for OTLP ingestion |
| FluentBit | otel-fluentbit | ✅ Running | Receives Docker fluentd logs, transforms via Lua |
| Loggen | otel-loggen | ✅ Running | Generates test logs via all three methods |
| Redpanda | otel-redpanda | ✅ Running | Kafka-compatible broker for GDP |
| Redpanda Console | otel-redpanda-console | ✅ Running | Web UI for Redpanda |
| GDP | otel-gdp | ✅ Running | Prometheus metrics to Kafka |

### Access Points

| Service | URL/Port | Description |
|---------|----------|-------------|
| ClickStack UI | http://localhost:38090 | HyperDX observability dashboard |
| OTLP HTTP | http://localhost:34318 | OTel Collector HTTP endpoint |
| OTLP gRPC | localhost:34317 | OTel Collector gRPC endpoint |
| ClickHouse HTTP | http://localhost:38123 | ClickHouse query interface |
| Redpanda Console | http://localhost:38085 | Kafka topic browser |
| Redpanda Kafka | localhost:39092 | Kafka protocol access |
| GDP Prometheus | http://localhost:38888/metrics | GDP metrics endpoint |

## What's Not Working

### ClickStack Bundled Collector

ClickStack's bundled OTel Collector fails to connect to our external ClickHouse:
- The `migrate` tool expects a different DSN format
- Connection errors: `clickhouse [ping]:: cannot ping clickhouse`
- Workaround: Using standalone OTel Collector instead

### ClickStack Auto-Configuration

ClickStack's auto-setup of connections/sources doesn't work with external ClickHouse:
- Manual configuration required in Team Settings UI
- Connection: `http://clickhouse:8123` (default user, no password)
- Log source: `default.otel_logs` table

## Current Architecture

```
┌──────────────────────────────────────────────────────────────────────────────┐
│                           Docker Compose Stack                                │
├──────────────────────────────────────────────────────────────────────────────┤
│                                                                               │
│  ┌──────────┐    Method 1: FluentBit (tail)    ┌───────────┐                 │
│  │  loggen  │ ─── json-file driver ──────────► │ fluentbit │ ──┐             │
│  │          │                                  │  (Lua)    │   │             │
│  │          │    Method 2: OTLP Direct         └───────────┘   │             │
│  │          │ ─── HTTP :4318 ────────────────► ┌─────────────┐ │             │
│  │          │                                  │    otel-    │ │             │
│  │          │    Method 3: Filelog             │  collector  │ ├──► ┌────────┐
│  │          │ ─── json-file driver ──────────► │  (filelog)  │ │    │clickhs │
│  └──────────┘                                  └─────────────┘ │    │ :8123  │
│                                                                │    │ :9000  │
│  ┌──────────┐                                                  │    └────────┘
│  │   gdp    │ ── Kafka ── ┌──────────┐ ── Kafka MV ────────────┘         │
│  │          │             │ redpanda │                                   │
│  └──────────┘             └──────────┘                                   │
│                                                                          │
│  ┌─────────────────┐                                                     │
│  │   clickstack    │ ◄─────────────── queries ───────────────────────────┘
│  │  (HyperDX UI)   │
│  │    :38090       │
│  └─────────────────┘
│                                                                               │
└──────────────────────────────────────────────────────────────────────────────┘
```

**Note:** Both FluentBit and OTel Collector read from Docker's JSON log files (json-file driver).
This requires mounting the Docker data directory which varies by system (default: `/var/lib/docker/containers`,
current setup uses custom path: `/home/das/docker/containers`).

## Nix Configuration

### Key Files

| File | Purpose |
|------|---------|
| `nix/docker-compose.nix` | Generates docker-compose.yaml with all services |
| `nix/constants.nix` | Central configuration (service names, images, databases) |
| `nix/ports.nix` | Port mappings for all deployment targets |
| `nix/gdp.nix` | GDP service and ClickHouse Kafka integration |
| `nix/otel-collector.nix` | OTel Collector image and OCB builder |

### Service Definitions in constants.nix

```nix
serviceNames = {
  clickhouse = "clickhouse";
  fluentbit = "fluentbit";
  loggen = "loggen";
  clickstack = "clickstack";
  otelCollector = "otel-collector";
  redpanda = "redpanda";
  redpandaConsole = "redpanda-console";
  gdp = "gdp";
};

externalImages = {
  clickhouse = "clickhouse/clickhouse-server:latest";
  clickstack = "clickhouse/clickstack-all-in-one:latest";
  otelCollector = "otel/opentelemetry-collector-contrib:0.96.0";
  redpanda = "docker.redpanda.com/redpandadata/redpanda:v24.3.8";
  redpandaConsole = "docker.redpanda.com/redpandadata/console:v2.8.4";
};
```

### Port Configuration (Docker Compose)

```nix
compose = {
  clickstackUi = 38090;
  clickstackOtlpGrpc = 34317;
  clickstackOtlpHttp = 34318;
  clickhouseHttp = 38123;
  clickhouseNative = 39000;
  redpandaKafka = 39092;
  redpandaSchemaRegistry = 38081;
  redpandaConsole = 38085;
  gdpPrometheus = 38888;
};
```

## Docker Compose Commands

```bash
# Start the stack
nix run .#compose-up

# Stop the stack
nix run .#compose-down

# View logs
nix run .#compose-logs

# Check status
nix run .#compose-ps

# Setup ClickHouse tables (first-time only)
nix run .#compose-setup

# Force stop (aggressive cleanup)
nix run .#compose-force-stop
```

## Database Schema

### OTel Logs Table (default.otel_logs)

```sql
CREATE TABLE IF NOT EXISTS default.otel_logs (
    Timestamp DateTime64(9),
    TimestampTime DateTime DEFAULT toDateTime(Timestamp),
    TraceId String,
    SpanId String,
    TraceFlags UInt8,
    SeverityText LowCardinality(String),
    SeverityNumber UInt8,
    ServiceName LowCardinality(String),
    Body String,
    ResourceSchemaUrl LowCardinality(String),
    ResourceAttributes Map(LowCardinality(String), String),
    ScopeSchemaUrl LowCardinality(String),
    ScopeName String,
    ScopeVersion LowCardinality(String),
    ScopeAttributes Map(LowCardinality(String), String),
    LogAttributes Map(LowCardinality(String), String),
    -- Custom loggen fields
    RandomNumber UInt32 DEFAULT 0,
    RandomString LowCardinality(String),
    Count UInt64 DEFAULT 0,
    Method LowCardinality(String) DEFAULT 'unknown',
    IngestionTimestamp DateTime64(9) DEFAULT now64(9)
)
ENGINE = MergeTree
PARTITION BY toDate(TimestampTime)
PRIMARY KEY (ServiceName, TimestampTime)
ORDER BY (ServiceName, TimestampTime, Timestamp)
TTL TimestampTime + INTERVAL 7 DAY;
```

## Verification Commands

```bash
# Count logs by pipeline
curl -s "http://localhost:38123/?query=SELECT+Body,count(*)+FROM+otel_logs+GROUP+BY+Body+ORDER+BY+count(*)+DESC+FORMAT+Pretty"

# Check recent logs
curl -s "http://localhost:38123/?query=SELECT+*+FROM+otel_logs+ORDER+BY+Timestamp+DESC+LIMIT+5+FORMAT+Pretty"

# Check OTel Collector status
docker logs otel-collector 2>&1 | tail -20

# Check loggen connectivity
docker logs otel-loggen 2>&1 | tail -20
```

## Known Issues

1. **ClickStack bundled collector incompatibility**: The bundled collector expects a specific ClickHouse DSN format that doesn't work with external ClickHouse. We use a standalone collector instead.

2. **Manual UI configuration required**: ClickStack doesn't auto-configure connections when using external ClickHouse. Manual setup in Team Settings is needed.

3. **Port 38080 conflict**: Changed ClickStack UI port from 38080 to 38090 due to local port conflict.

4. **ClickHouse 26.x incompatibility**: HyperDX has `EXPLAIN ESTIMATE` syntax errors with ClickHouse 26.x. Using official ClickHouse 25.x image.

## Next Steps

1. Add dashboards for loggen metrics (RandomNumber, RandomString distributions)
2. Consider automating ClickStack connection/source setup
3. Make Docker data directory path configurable (currently hardcoded to `/home/das/docker/containers`)
4. Commit changes to gdp branch
