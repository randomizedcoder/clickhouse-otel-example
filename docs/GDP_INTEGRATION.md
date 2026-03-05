# GDP Integration

GDP (Go Data Pipeline) integration adds Prometheus metrics collection via Kafka/Redpanda to ClickHouse, complementing the existing OpenTelemetry logs pipeline.

## Architecture

```
OTEL LOGS PIPELINE:                    GDP METRICS PIPELINE:
┌─────────┐     ┌───────────┐          ┌─────────┐     ┌───────────┐
│ loggen  │────▶│ FluentBit │──┐   ┌───│   GDP   │────▶│ Redpanda  │
└─────────┘     └───────────┘  │   │   └─────────┘     └───────────┘
                               │   │                          │
                               ▼   ▼                    (Kafka proto)
                         ┌─────────────┐                      │
                         │ ClickHouse  │◀─────────────────────┘
                         │             │              (Kafka Engine)
                         │ otel_logs   │
                         │ gdp.Proto*  │
                         └─────────────┘
```

## Components

| Component | Image Source | Description |
|-----------|--------------|-------------|
| GDP | Nix-built from source | Prometheus metrics collector |
| Redpanda | Official Docker image | Kafka-compatible message broker |
| Redpanda Console | Official Docker image | Web UI for Kafka topics |
| ClickHouse | Nix-built | Extended with Kafka engine + Protobuf support |

## Data Flow

1. **GDP** scrapes its own Prometheus `/metrics` endpoint
2. **GDP** serializes metrics as Protobuf (`PromRecordCounter` message)
3. **GDP** produces to Redpanda topic `ProtobufSingle`
4. **ClickHouse Kafka Engine** consumes from `ProtobufSingle` topic
5. **Materialized View** moves data to `gdp.ProtobufSingle` MergeTree table

## Files Changed

### New Files

#### `nix/constants.nix`
Central constants for GDP integration:
- Service names and container names
- External image versions (Redpanda, Redpanda Console)
- GDP source configuration (GitHub repo, revision, hash)
- Kafka topics (`ProtobufSingle`, `ProtobufListProtodelim`)
- GDP runtime config (poll frequency, timeouts)
- Data retention periods

#### `nix/gdp.nix`
GDP build and configuration module:
- Fetches GDP source from GitHub using `fetchFromGitHub`
- Builds GDP binary using `buildGoModule` (static, CGO disabled)
- Creates container image using `mkImage`
- Extracts Protobuf schemas from GDP repo
- Generates ClickHouse Kafka config and init SQL

### Modified Files

#### `nix/ports.nix`
Added ports for GDP integration:
```nix
services = {
  # GDP Integration - Redpanda
  redpandaKafkaInternal = 9092;
  redpandaKafkaExternal = 19092;
  redpandaSchemaRegistryInternal = 8081;
  redpandaSchemaRegistryExternal = 18081;
  redpandaAdminApi = 9644;
  redpandaRpc = 33145;
  redpandaConsole = 8080;

  # GDP
  gdpPrometheus = 8888;
};

compose = {
  redpandaKafka = 39092;
  redpandaSchemaRegistry = 38081;
  redpandaConsole = 38085;
  gdpPrometheus = 38888;
};
```

#### `nix/containers.nix`
- Added GDP image to `imageConfigs` and `allImagesList`
- Added `includeUsers = true` for ClickHouse (needed for user resolution)
- Added `format_schemas` directory to ClickHouse extraDirs
- Exports `gdpInitSql`, `formatSchemas`, `kafkaConfig`

#### `nix/lib/containers.nix`
Added `includeUsers` option:
```nix
userPackages = [ pkgs.fakeNss ]; # Provides /etc/passwd and /etc/group
```

#### `nix/docker-compose.nix`
Added three new services:
- **Redpanda**: Kafka-compatible broker in dev-container mode
- **Redpanda Console**: Web UI for topic inspection
- **GDP**: Nix-built metrics collector

Updated ClickHouse service:
- Switched from official image to Nix-built `clickhouse:latest`
- Added Protobuf schema mounts
- Added Kafka engine configuration
- Added dependency on Redpanda health

#### `flake.nix`
- Added `gdp-image` to packages
- Added `fetchFromGitHub`, `buildGoModule`, `runCommand` to compose imports

## ClickHouse Schema

### Database: `gdp`

#### Table: `gdp.ProtobufSingle`
MergeTree table storing metrics:
```sql
CREATE TABLE gdp.ProtobufSingle (
    Timestamp_Ns DateTime64(9,'UTC'),
    Hostname LowCardinality(String),
    Pop LowCardinality(String),
    Label LowCardinality(String),
    Tag LowCardinality(String),
    Poll_Counter UInt64,
    Record_Counter UInt64,
    Function LowCardinality(String),
    Variable LowCardinality(String),
    Type LowCardinality(String),
    Value Float64
)
ENGINE = MergeTree()
PARTITION BY toYYYYMM(Timestamp_Ns)
ORDER BY (Timestamp_Ns, Hostname, Pop, Label, Tag, Poll_Counter, Record_Counter)
TTL toDateTime(Timestamp_Ns) + INTERVAL 14 DAY;
```

#### Table: `gdp.ProtobufSingle_kafka`
Kafka engine table consuming from Redpanda:
```sql
CREATE TABLE gdp.ProtobufSingle_kafka (...)
ENGINE = Kafka
SETTINGS
    kafka_broker_list = 'redpanda:9092',
    kafka_topic_list = 'ProtobufSingle',
    kafka_group_name = 'clickhouse_gdp_consumer',
    kafka_schema = 'prometheus_protolist.proto:PromRecordCounter',
    kafka_format = 'ProtobufSingle';
```

#### View: `gdp.ProtobufSingle_mv`
Materialized view moving data from Kafka to MergeTree:
```sql
CREATE MATERIALIZED VIEW gdp.ProtobufSingle_mv
TO gdp.ProtobufSingle
AS SELECT * FROM gdp.ProtobufSingle_kafka;
```

## Protobuf Schema Configuration (Critical Details)

Getting ClickHouse to correctly parse Protobuf messages from Kafka requires precise configuration. This section documents the exact requirements and common pitfalls.

### Proto File Structure

The GDP repository contains two proto files in `build/containers/clickhouse/format_schemas/`:

```
format_schemas/
├── google/                      # Google protobuf dependencies
├── prometheus.proto             # Standalone PromRecordCounter
└── prometheus_protolist.proto   # PromRecordCounter + Envelope wrapper
```

**Both files define the same message in the same package:**
```protobuf
package prometheus.v1;

message PromRecordCounter {
    double timestamp_ns = 10;
    string hostname = 20;
    // ... etc
}
```

### The Duplicate Message Problem

**Problem:** If both `prometheus.proto` and `prometheus_protolist.proto` are present in ClickHouse's `format_schemas` directory, ClickHouse's protobuf parser fails with:

```
Code: 434. DB::Exception: Cannot parse 'prometheus_protolist.proto' file,
found an error at line 91, column 8, "prometheus.v1.PromRecordCounter"
is already defined in file "prometheus.proto"
```

**Solution:** Only mount `prometheus_protolist.proto` (and the `google/` directory for dependencies):

```nix
# nix/gdp.nix
formatSchemas = runCommand "gdp-format-schemas" { } ''
  mkdir -p $out
  if [ -d "${gdpSrc}/build/containers/clickhouse/format_schemas" ]; then
    # ONLY copy prometheus_protolist.proto - NOT prometheus.proto
    cp ${gdpSrc}/build/containers/clickhouse/format_schemas/prometheus_protolist.proto $out/
    cp -r ${gdpSrc}/build/containers/clickhouse/format_schemas/google $out/
  fi
'';
```

### Schema Reference Format

The `kafka_schema` setting must use the exact format: `<filename>:<MessageName>`

**Correct:**
```sql
kafka_schema = 'prometheus_protolist.proto:PromRecordCounter'
```

**Wrong - includes package path:**
```sql
kafka_schema = 'prometheus_protolist.proto:prometheus.v1.PromRecordCounter'  -- WRONG
kafka_schema = 'prometheus:prometheus.v1.PromRecordCounter'  -- WRONG
kafka_schema = 'prometheus:PromRecordCounter'  -- WRONG (file extension required)
```

The format is:
- First part: **filename with extension** (e.g., `prometheus_protolist.proto`)
- Second part: **message name only** (e.g., `PromRecordCounter`, not the full package path)

### Kafka Format Setting

GDP produces single Protobuf messages (not length-delimited streams). Use `ProtobufSingle`:

**Correct:**
```sql
kafka_format = 'ProtobufSingle'
```

**Wrong:**
```sql
kafka_format = 'Protobuf'  -- For length-delimited streams, causes parse errors
kafka_format = 'ProtobufList'  -- For repeated messages in Envelope
```

The `ProtobufSingle` format expects one complete Protobuf message per Kafka message, which matches GDP's output.

### Column Type Mapping

ClickHouse column types must match the Protobuf field types. GDP's proto uses:

| Proto Type | Proto Field | ClickHouse Type | Notes |
|------------|-------------|-----------------|-------|
| `double` | `timestamp_ns` | `DateTime64(9,'UTC')` | ClickHouse auto-converts |
| `string` | `hostname`, etc. | `LowCardinality(String)` | Optimizes storage |
| `uint64` | `poll_counter`, etc. | `UInt64` | Direct mapping |
| `double` | `value` | `Float64` | Direct mapping |

**Important:** Column names in ClickHouse are case-insensitive, but the GDP schema uses `Timestamp_Ns`, `Hostname`, etc. with underscores. These map correctly to the proto fields `timestamp_ns`, `hostname` via field numbers, not names.

### Format Schemas Directory

ClickHouse looks for proto files in the path configured by `format_schema_path`:

```xml
<!-- kafka.xml mounted to /opt/clickhouse-config/kafka.xml -->
<clickhouse>
    <kafka>
        <debug>cgrp</debug>
        <auto_offset_reset>smallest</auto_offset_reset>
    </kafka>
    <format_schema_path>/var/lib/clickhouse/format_schemas/</format_schema_path>
</clickhouse>
```

The proto files are mounted via docker-compose:
```yaml
volumes:
  - ${gdp.formatSchemas}:/var/lib/clickhouse/format_schemas:ro
```

**Verify the mount is correct:**
```bash
docker exec otel-clickhouse ls -la /var/lib/clickhouse/format_schemas/
# Should show:
# - google/           (directory)
# - prometheus_protolist.proto  (file)
# Should NOT show prometheus.proto
```

### Complete Working Kafka Table Definition

```sql
CREATE TABLE IF NOT EXISTS gdp.ProtobufSingle_kafka (
    Timestamp_Ns DateTime64(9,'UTC') CODEC(DoubleDelta, LZ4),
    Hostname LowCardinality(String) CODEC(LZ4),
    Pop LowCardinality(String) CODEC(LZ4),
    Label LowCardinality(String) CODEC(LZ4),
    Tag LowCardinality(String) CODEC(LZ4),
    Poll_Counter UInt64 CODEC(DoubleDelta, LZ4),
    Record_Counter UInt64 CODEC(DoubleDelta, LZ4),
    Function LowCardinality(String) CODEC(LZ4),
    Variable LowCardinality(String) CODEC(LZ4),
    Type LowCardinality(String) CODEC(LZ4),
    Value Float64
)
ENGINE = Kafka
SETTINGS
    kafka_broker_list = 'redpanda:9092',
    kafka_topic_list = 'ProtobufSingle',
    kafka_group_name = 'clickhouse_gdp_consumer',
    kafka_schema = 'prometheus_protolist.proto:PromRecordCounter',  -- filename:MessageName
    kafka_handle_error_mode = 'stream',  -- Log errors to virtual columns
    kafka_poll_max_batch_size = 1024,
    kafka_format = 'ProtobufSingle';  -- Single message per Kafka record
```

Key settings explained:
- `kafka_schema`: File and message name (no package path)
- `kafka_format`: `ProtobufSingle` for one message per Kafka record
- `kafka_handle_error_mode = 'stream'`: Errors go to `_error` virtual column instead of failing

### Debugging Protobuf Issues

**1. Check what's in format_schemas:**
```bash
docker exec otel-clickhouse ls /var/lib/clickhouse/format_schemas/
```

**2. Read a proto file to verify content:**
```bash
docker exec otel-clickhouse head -60 /var/lib/clickhouse/format_schemas/prometheus_protolist.proto
```

**3. Check Kafka consumer for exceptions:**
```sql
SELECT
    database,
    table,
    num_messages_read,
    exceptions.time,
    exceptions.text
FROM system.kafka_consumers
FORMAT Vertical;
```

**4. Consume raw message from Redpanda to verify format:**
```bash
docker exec otel-redpanda rpk topic consume ProtobufSingle --num 1 --offset -1
```

**5. If consumer shows messages read but target table empty:**
- Check `exceptions.text` array in `system.kafka_consumers`
- Verify materialized view exists and is attached
- Check that column types match between Kafka table and target table

## Configuration

### GDP Runtime Config
Defined in `nix/constants.nix`:
```nix
gdpConfig = {
  pollFrequency = "10s";   # How often to scrape metrics
  pollTimeout = "5s";      # Timeout per scrape
  kafkaProduceTimeout = "2s";
  debugLevel = "11";
  goMaxProcs = "2";
};
```

### Data Retention
```nix
retention = {
  otelLogs = 7;      # 7 days for OTel logs
  gdpMetrics = 14;   # 14 days for GDP metrics
};
```

## Usage

### Start the Stack
```bash
nix run .#compose-up
```

### Initialize Tables
```bash
nix run .#compose-setup
```
This creates:
- `default.otel_logs` - OTel logs table
- `gdp.ProtobufSingle` - GDP metrics MergeTree
- `gdp.ProtobufSingle_kafka` - Kafka engine table
- `gdp.ProtobufSingle_mv` - Materialized view

### Query GDP Metrics
```bash
# Count metrics
curl 'http://localhost:38123/?query=SELECT+count()+FROM+gdp.ProtobufSingle'

# View recent metrics
curl 'http://localhost:38123/?query=SELECT+*+FROM+gdp.ProtobufSingle+ORDER+BY+Timestamp_Ns+DESC+LIMIT+10+FORMAT+Pretty'

# Metrics by function
curl 'http://localhost:38123/?query=SELECT+Function,count()+FROM+gdp.ProtobufSingle+GROUP+BY+Function+FORMAT+Pretty'
```

### Access Points
| Service | URL |
|---------|-----|
| Redpanda Console | http://localhost:38085 |
| Redpanda Kafka | localhost:39092 |
| GDP Prometheus | http://localhost:38888/metrics |
| ClickHouse HTTP | http://localhost:38123 |

### Check Kafka Consumer Health
```sql
SELECT database, table, num_messages_read, last_poll_time, exceptions.text
FROM system.kafka_consumers
FORMAT Vertical;
```

## Design Decisions

### Why Nix-built GDP?
GDP is a simple Go application that builds cleanly with `buildGoModule`. Building from source ensures:
- Reproducible builds
- Version pinning via Nix hashes
- Consistent with other Nix-built containers in the project

### Why Official Redpanda Images?
Redpanda is a complex C++ application with:
- Custom memory allocators
- Kernel bypass networking (optional)
- Complex build dependencies

Building Redpanda in Nix would be impractical. The official images are well-maintained and production-ready.

### Why `prometheus_protolist.proto`?
The GDP repo contains two proto files:
- `prometheus.proto` - Standalone `PromRecordCounter`
- `prometheus_protolist.proto` - Both standalone and nested in `Envelope`

Both define `prometheus.v1.PromRecordCounter`. To avoid duplicate message conflicts in ClickHouse's protobuf parser, we only mount `prometheus_protolist.proto`.

### Why `fakeNss` for ClickHouse?
ClickHouse logs warnings when it can't resolve user names. The `fakeNss` package provides minimal `/etc/passwd` and `/etc/group` files, eliminating these warnings without adding a full user management system.

## Troubleshooting

### No Data in `gdp.ProtobufSingle`
1. Check GDP is producing:
   ```bash
   docker logs otel-gdp
   ```
2. Check topic has messages:
   ```bash
   docker exec otel-redpanda rpk topic consume ProtobufSingle --num 1
   ```
3. Check Kafka consumer status:
   ```sql
   SELECT * FROM system.kafka_consumers FORMAT Vertical;
   ```

### Protobuf Parse Errors
If you see "Protobuf messages are corrupted":
1. Verify only `prometheus_protolist.proto` is in format_schemas
2. Check schema reference: `prometheus_protolist.proto:PromRecordCounter`
3. Ensure format is `ProtobufSingle` (not `Protobuf`)

### Consumer Not Advancing
1. Check Redpanda is healthy:
   ```bash
   docker exec otel-redpanda rpk cluster health
   ```
2. Verify consumer group:
   ```bash
   docker exec otel-redpanda rpk group describe clickhouse_gdp_consumer
   ```

## Source

GDP is sourced from: https://github.com/randomizedcoder/gdp
