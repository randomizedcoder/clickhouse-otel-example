# GDP: Fetch source, build Go binary, create container image
# GDP (Go Data Pipeline) collects Prometheus metrics and sends them to Kafka/ClickHouse
{ lib
, pkgs
, fetchFromGitHub
, buildGoModule
, writeText
, runCommand
, constants
, containerLib
, ports
}:

let
  # Fetch GDP repository
  gdpSrc = fetchFromGitHub {
    inherit (constants.gdpSource) owner repo rev hash;
  };

  # Build GDP Go binary
  gdpBinary = buildGoModule {
    pname = "gdp";
    version = constants.versions.gdp;
    src = gdpSrc;

    # Use vendored dependencies or set vendorHash
    # This hash will need to be updated after first build attempt
    vendorHash = "sha256-wCGf0+3++4MnIMthEVxPj7fUsnv+5/Lndr3dgZuclpM=";

    subPackages = [ "cmd/gdp" ];

    ldflags = [
      "-s"
      "-w"
      "-X main.version=${constants.versions.gdp}"
      "-X main.commit=${constants.gdpSource.rev}"
    ];

    # Build without CGO for static binary
    env.CGO_ENABLED = "0";

    meta = {
      description = "Go Data Pipeline - Prometheus metrics to Kafka/ClickHouse";
      homepage = "https://github.com/${constants.gdpSource.owner}/${constants.gdpSource.repo}";
      license = lib.licenses.asl20;
      mainProgram = "gdp";
    };
  };

  # Build GDP container image using existing mkImage pattern
  gdpImage = containerLib.mkImage {
    name = "gdp";
    tag = constants.versions.gdp;
    packages = [ gdpBinary ];
    pathsToLink = [ "/bin" ];
    entrypoint = [ "/bin/gdp" ];
    env = [
      "DEBUG_LEVEL=${constants.gdpConfig.debugLevel}"
      "POLL_FREQUENCY=${constants.gdpConfig.pollFrequency}"
      "POLL_TIMEOUT=${constants.gdpConfig.pollTimeout}"
      "KAFKA_PRODUCE_TIMEOUT=${constants.gdpConfig.kafkaProduceTimeout}"
      "GOMAXPROCS=${constants.gdpConfig.goMaxProcs}"
    ];
    exposedPorts = [ ports.services.gdpPrometheus ];
    description = "Go Data Pipeline - Prometheus metrics collector";
    includeTls = true;
    includeTz = true;
  };

  # Extract ClickHouse format schemas from GDP repo
  # Include prometheus.proto for ProtobufSingle format
  formatSchemas = runCommand "gdp-format-schemas" { } ''
    mkdir -p $out
    if [ -d "${gdpSrc}/build/containers/clickhouse/format_schemas" ]; then
      cp ${gdpSrc}/build/containers/clickhouse/format_schemas/prometheus.proto $out/
      cp ${gdpSrc}/build/containers/clickhouse/format_schemas/prometheus_protolist.proto $out/
      cp -r ${gdpSrc}/build/containers/clickhouse/format_schemas/google $out/
    fi
  '';

  # Proto files for GDP runtime (schema registry registration)
  protoFiles = runCommand "gdp-proto-files" { } ''
    mkdir -p $out
    cp ${gdpSrc}/build/containers/clickhouse/format_schemas/prometheus.proto $out/
    cp ${gdpSrc}/build/containers/clickhouse/format_schemas/prometheus_protolist.proto $out/
  '';

  # ClickHouse Kafka engine config with format schema path
  kafkaConfig = runCommand "gdp-kafka-config" { } ''
    mkdir -p $out
    cat > $out/kafka.xml << 'EOF'
    <clickhouse>
        <kafka>
            <debug>cgrp</debug>
            <auto_offset_reset>smallest</auto_offset_reset>
        </kafka>
        <format_schema_path>/var/lib/clickhouse/format_schemas/</format_schema_path>
    </clickhouse>
    EOF
  '';

  # Combined GDP SQL init script
  # This creates the GDP database and tables for storing Prometheus metrics
  # Schema matches github.com/randomizedcoder/gdp exactly
  gdpInitSql = writeText "init-gdp.sql" ''
    -- GDP Database and Tables
    -- Source: github.com/${constants.gdpSource.owner}/${constants.gdpSource.repo}
    -- Creates tables for storing Prometheus metrics via Kafka using Protobuf format

    CREATE DATABASE IF NOT EXISTS ${constants.databases.gdp};

    -- ProtobufSingle table for storing Prometheus metrics
    -- Schema matches prometheus.proto PromRecordCounter message
    CREATE TABLE IF NOT EXISTS ${constants.databases.gdp}.ProtobufSingle (
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
    ENGINE = MergeTree()
    PARTITION BY toYYYYMM(Timestamp_Ns)
    ORDER BY (Timestamp_Ns, Hostname, Pop, Label, Tag, Poll_Counter, Record_Counter)
    TTL toDateTime(Timestamp_Ns) + INTERVAL ${toString constants.retention.gdpMetrics} DAY;

    -- Kafka engine table using ProtobufSingle format
    -- Reads from Redpanda using prometheus.proto schema
    CREATE TABLE IF NOT EXISTS ${constants.databases.gdp}.ProtobufSingle_kafka (
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
        kafka_broker_list = '${constants.serviceNames.redpanda}:${toString ports.services.redpandaKafkaInternal}',
        kafka_topic_list = '${constants.kafkaTopics.protobufSingle}',
        kafka_group_name = 'clickhouse_gdp_consumer',
        kafka_schema = 'prometheus.proto:PromRecordCounter',
        kafka_handle_error_mode = 'stream',
        kafka_poll_max_batch_size = 1024,
        kafka_format = 'ProtobufSingle';

    -- Materialized view to move data from Kafka to MergeTree
    CREATE MATERIALIZED VIEW IF NOT EXISTS ${constants.databases.gdp}.ProtobufSingle_mv
    TO ${constants.databases.gdp}.ProtobufSingle
    AS SELECT * FROM ${constants.databases.gdp}.ProtobufSingle_kafka;

    -- GDP logs view for HyperDX compatibility
    -- Transforms GDP metrics into log format for visualization in HyperDX UI
    CREATE OR REPLACE VIEW default.gdp_logs AS
    SELECT
        Timestamp_Ns as Timestamp,
        toDateTime(Timestamp_Ns) as TimestampTime,
        Hostname as ServiceName,
        'INFO' as SeverityText,
        concat(Function, ': ', Variable, ' = ', toString(Value)) as Body,
        '' as TraceId,
        '' as SpanId,
        Function,
        Variable,
        Type,
        Value,
        Poll_Counter,
        Record_Counter
    FROM ${constants.databases.gdp}.ProtobufSingle;
  '';

in
{
  inherit gdpSrc gdpBinary gdpImage formatSchemas kafkaConfig gdpInitSql protoFiles;

  # Image config for containers.nix integration
  imageConfig = {
    packages = [ gdpBinary ];
    pathsToLink = [ "/bin" ];
    entrypoint = [ "/bin/gdp" ];
    env = [
      "DEBUG_LEVEL=${constants.gdpConfig.debugLevel}"
      "POLL_FREQUENCY=${constants.gdpConfig.pollFrequency}"
      "POLL_TIMEOUT=${constants.gdpConfig.pollTimeout}"
      "KAFKA_PRODUCE_TIMEOUT=${constants.gdpConfig.kafkaProduceTimeout}"
      "GOMAXPROCS=${constants.gdpConfig.goMaxProcs}"
    ];
    exposedPorts = [ ports.services.gdpPrometheus ];
    description = "Go Data Pipeline - Prometheus metrics to ClickHouse";
    includeTls = true;
    includeTz = true;
  };
}
