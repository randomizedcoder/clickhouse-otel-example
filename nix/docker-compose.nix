# Docker Compose Generator
#
# Generates docker-compose.yaml with configuration from ports.nix and constants.nix
# This allows running the stack directly on the host without a MicroVM.
#
# Note: Uses official images where the Nix-built ones have K8s-specific configs.
# GDP Integration: Adds Redpanda (Kafka), Redpanda Console, and GDP services
{ lib, pkgs, writeText, fetchFromGitHub ? pkgs.fetchFromGitHub, buildGoModule ? pkgs.buildGoModule, runCommand ? pkgs.runCommand }:

let
  ports = import ./ports.nix;
  constants = import ./constants.nix { inherit pkgs; };
  containerLib = import ./lib/containers.nix { inherit lib pkgs; };

  # Import GDP module for SQL init and configs
  gdp = import ./gdp.nix {
    inherit lib pkgs fetchFromGitHub buildGoModule writeText runCommand;
    inherit constants containerLib ports;
  };

  # ClickHouse users config - allow default user from any host without password
  # Required for official ClickHouse image (25.6) which restricts default to localhost
  clickhouseUsersConfig = writeText "default-allow-all.xml" ''
    <clickhouse>
      <users>
        <default>
          <password></password>
          <networks>
            <ip>::/0</ip>
          </networks>
          <profile>default</profile>
          <quota>default</quota>
          <access_management>1</access_management>
        </default>
      </users>
    </clickhouse>
  '';

  # Lua transform script for converting logs to OTel format
  luaTransform = writeText "transform.lua" ''
    -- Transform FluentBit records to OTel log format for ClickHouse
    local severity_map = {
      debug = { text = "DEBUG", num = 5 },
      info = { text = "INFO", num = 9 },
      warn = { text = "WARN", num = 13 },
      warning = { text = "WARN", num = 13 },
      error = { text = "ERROR", num = 17 },
      fatal = { text = "FATAL", num = 21 },
    }

    function format_timestamp(ts)
      if type(ts) ~= "number" then
        return os.date("!%Y-%m-%d %H:%M:%S.000000000")
      end
      local seconds = math.floor(ts)
      local nanos = math.floor((ts - seconds) * 1e9)
      return string.format("%s.%09d", os.date("!%Y-%m-%d %H:%M:%S", seconds), nanos)
    end

    function transform_to_otel(tag, timestamp, record)
      -- Parse JSON log if present
      local level = record.level or "info"
      local ts = record.ts or timestamp
      local msg = record.msg or record.log or ""
      local caller = record.caller or ""
      local count = record.count or 0
      local random_number = record.random_number or 0
      local random_string = record.random_string or ""

      -- Get service name from tag (format: loggen, docker.loggen, etc)
      local service_name = tag:match("%.?([^%.]+)$") or "unknown"

      -- Map severity
      local sev = severity_map[level] or severity_map.info

      -- Build OTel record - Map fields as Lua tables for proper JSON serialization
      local otel = {
        Timestamp = format_timestamp(ts),
        TraceId = "",
        SpanId = "",
        TraceFlags = 0,
        SeverityText = sev.text,
        SeverityNumber = sev.num,
        ServiceName = service_name,
        Body = msg,
        ResourceSchemaUrl = "",
        ResourceAttributes = { ["service.name"] = service_name },
        ScopeSchemaUrl = "",
        ScopeName = service_name,
        ScopeVersion = "1.0.0",
        ScopeAttributes = {},
        LogAttributes = { caller = caller },
        RandomNumber = random_number,
        RandomString = random_string,
        Count = count,
      }

      return 1, timestamp, otel
    end
  '';

  # FluentBit config for docker-compose (reads Docker log files directly)
  fluentbitConf = writeText "fluent-bit.conf" ''
    [SERVICE]
        Flush         1
        Log_Level     info
        Parsers_File  /fluent-bit/etc/parsers.conf
        HTTP_Server   On
        HTTP_Listen   0.0.0.0
        HTTP_Port     ${toString ports.services.fluentbitMetrics}

    # Read Docker container log files directly
    # Docker writes JSON logs to /home/das/docker/containers/<id>/<id>-json.log
    [INPUT]
        Name          tail
        Tag           docker.loggen
        Path          /home/das/docker/containers/*/*-json.log
        Parser        docker
        Refresh_Interval 1
        Rotate_Wait   30
        Mem_Buf_Limit 5MB
        Skip_Long_Lines On
        DB            /fluent-bit/tail.db

    # Parse the nested JSON from Docker's log wrapper
    # The log field contains JSON like: {"level":"info","ts":...,"random_number":42,...}
    [FILTER]
        Name          parser
        Match         *
        Key_Name      log
        Parser        json
        Reserve_Data  On

    # Filter to only process Method 1 logs (FluentBit pipeline)
    # Match logs containing "FluentBit" in the msg field to avoid processing other methods
    [FILTER]
        Name          grep
        Match         *
        Regex         msg FluentBit

    [FILTER]
        Name          lua
        Match         *
        script        /fluent-bit/etc/transform.lua
        call          transform_to_otel

    [OUTPUT]
        Name          http
        Match         *
        Host          clickhouse
        Port          ${toString ports.services.clickhouseHttp}
        URI           /?query=INSERT+INTO+otel_logs+FORMAT+JSONEachRow
        Format        json_lines
        Json_date_key Timestamp
        Json_date_format epoch
  '';

  # FluentBit parsers config
  fluentbitParsers = writeText "parsers.conf" ''
    # Docker JSON log format parser
    [PARSER]
        Name        docker
        Format      json
        Time_Key    time
        Time_Format %Y-%m-%dT%H:%M:%S.%L
        Time_Keep   On

    # Nested JSON log content parser
    [PARSER]
        Name        json
        Format      json
        Time_Key    ts
        Time_Format %s.%L
  '';

  # OTel Collector config for ClickHouse export
  # Supports both OTLP (Method 2) and Filelog (Method 3) receivers
  otelCollectorConfig = writeText "otel-collector-config.yaml" ''
    receivers:
      # Method 2: OTLP Direct - receives logs from OTel SDK
      otlp:
        protocols:
          grpc:
            endpoint: 0.0.0.0:4317
          http:
            endpoint: 0.0.0.0:4318

      # Method 3: Filelog - reads container log files directly
      # Docker stores logs at /home/das/docker/containers/<id>/<id>-json.log
      filelog:
        include:
          - /home/das/docker/containers/*/*-json.log
        start_at: end
        include_file_path: true
        operators:
          # Parse Docker's JSON log wrapper: {"log": "...", "stream": "stdout", "time": "..."}
          - type: json_parser
            id: docker_parser
          # Only process stdout (skip stderr)
          - type: filter
            id: filter_stderr
            expr: 'attributes.stream != "stdout"'
          # Move the log field to body for further processing
          - type: move
            from: attributes.log
            to: body
          # Parse our JSON log content from body
          - type: json_parser
            id: log_parser
            parse_from: body
            parse_to: attributes
          # Only process Method 3 logs (contains "filelog receiver" in msg)
          - type: filter
            id: filter_method3
            expr: 'attributes.msg == nil or not (attributes.msg contains "filelog receiver")'
          # Set body to the msg field for display
          - type: move
            id: set_body
            from: attributes.msg
            to: body

    processors:
      batch:
        timeout: 1s
        send_batch_size: 1024

      # Transform processor to fix timestamps and set severity
      transform/filelog:
        log_statements:
          - context: log
            statements:
              # Fix timestamp: use observed_time if time is not set
              - set(time_unix_nano, observed_time_unix_nano) where time_unix_nano == 0
              # Set severity from level attribute
              - set(severity_text, "INFO") where attributes["level"] == "info"
              - set(severity_number, 9) where attributes["level"] == "info"
              - set(severity_text, "DEBUG") where attributes["level"] == "debug"
              - set(severity_number, 5) where attributes["level"] == "debug"
              - set(severity_text, "WARN") where attributes["level"] == "warn"
              - set(severity_number, 13) where attributes["level"] == "warn"
              - set(severity_text, "ERROR") where attributes["level"] == "error"
              - set(severity_number, 17) where attributes["level"] == "error"

    exporters:
      clickhouse:
        endpoint: tcp://${constants.serviceNames.clickhouse}:${toString ports.services.clickhouseNative}
        database: ${constants.databases.otelLogs}
        logs_table_name: otel_logs
        timeout: 5s
        retry_on_failure:
          enabled: true
          initial_interval: 5s
          max_interval: 30s
          max_elapsed_time: 300s

    service:
      pipelines:
        # Method 2: OTLP Direct pipeline
        logs/otlp:
          receivers: [otlp]
          processors: [batch]
          exporters: [clickhouse]
        # Method 3: Filelog pipeline
        logs/filelog:
          receivers: [filelog]
          processors: [transform/filelog, batch]
          exporters: [clickhouse]
  '';

  # Generate docker-compose.yaml
  composeFile = writeText "docker-compose.yaml" ''
    # Generated by Nix from nix/docker-compose.nix
    # Configuration sourced from nix/ports.nix
    #
    # Usage:
    #   nix run .#compose-up    # Start the stack
    #   nix run .#compose-down  # Stop the stack
    #   nix run .#compose-logs  # View logs

    services:
      # ============================================
      # Redpanda (Kafka-compatible broker) - GDP Integration
      # ============================================
      ${constants.serviceNames.redpanda}:
        image: ${constants.externalImages.redpanda}
        container_name: ${constants.containerNames.redpanda}
        command:
          - redpanda
          - start
          - --kafka-addr=internal://0.0.0.0:${toString ports.services.redpandaKafkaInternal},external://0.0.0.0:${toString ports.services.redpandaKafkaExternal}
          - --advertise-kafka-addr=internal://${constants.serviceNames.redpanda}:${toString ports.services.redpandaKafkaInternal},external://localhost:${toString ports.services.redpandaKafkaExternal}
          - --schema-registry-addr=internal://0.0.0.0:${toString ports.services.redpandaSchemaRegistryInternal},external://0.0.0.0:${toString ports.services.redpandaSchemaRegistryExternal}
          - --rpc-addr=${constants.serviceNames.redpanda}:${toString ports.services.redpandaRpc}
          - --advertise-rpc-addr=${constants.serviceNames.redpanda}:${toString ports.services.redpandaRpc}
          - --mode=dev-container
          - --smp=1
          - --default-log-level=info
        ports:
          - "${toString ports.compose.redpandaKafka}:${toString ports.services.redpandaKafkaInternal}"
          - "${toString ports.compose.redpandaSchemaRegistry}:${toString ports.services.redpandaSchemaRegistryExternal}"
        volumes:
          - redpanda-data:/var/lib/redpanda/data
        healthcheck:
          test: ["CMD", "rpk", "cluster", "health"]
          interval: 10s
          timeout: 5s
          retries: 5
        networks:
          - ${constants.network.name}

      # ============================================
      # Redpanda Console (Web UI) - GDP Integration
      # ============================================
      ${constants.serviceNames.redpandaConsole}:
        image: ${constants.externalImages.redpandaConsole}
        container_name: ${constants.containerNames.redpandaConsole}
        ports:
          - "${toString ports.compose.redpandaConsole}:${toString ports.services.redpandaConsole}"
        entrypoint: /bin/sh
        command: -c 'echo "$$CONSOLE_CONFIG_FILE" > /tmp/config.yml; /app/console'
        environment:
          CONFIG_FILEPATH: /tmp/config.yml
          CONSOLE_CONFIG_FILE: |
            kafka:
              brokers: ["${constants.serviceNames.redpanda}:${toString ports.services.redpandaKafkaInternal}"]
              protobuf:
                enabled: true
                schemaRegistry:
                  enabled: true
              schemaRegistry:
                enabled: true
                urls: ["http://${constants.serviceNames.redpanda}:${toString ports.services.redpandaSchemaRegistryInternal}"]
            redpanda:
              adminApi:
                enabled: true
                urls: ["http://${constants.serviceNames.redpanda}:${toString ports.services.redpandaAdminApi}"]
        depends_on:
          ${constants.serviceNames.redpanda}:
            condition: service_healthy
        networks:
          - ${constants.network.name}

      # ============================================
      # GDP (Go Data Pipeline) - Prometheus metrics to Kafka
      # ============================================
      ${constants.serviceNames.gdp}:
        image: gdp:latest
        container_name: ${constants.containerNames.gdp}
        command:
          - -dest=kafka:${constants.serviceNames.redpanda}:${toString ports.services.redpandaKafkaInternal}
          - -kafkaSchemaUrl=http://${constants.serviceNames.redpanda}:${toString ports.services.redpandaSchemaRegistryInternal}
          - -frequency=${constants.gdpConfig.pollFrequency}
          - -timeout=${constants.gdpConfig.pollTimeout}
          - -d=${constants.gdpConfig.debugLevel}
        volumes:
          - ${gdp.protoFiles}/prometheus.proto:/prometheus.proto:ro
          - ${gdp.protoFiles}/prometheus_protolist.proto:/prometheus_protolist.proto:ro
        ports:
          - "${toString ports.compose.gdpPrometheus}:${toString ports.services.gdpPrometheus}"
        restart: unless-stopped
        deploy:
          resources:
            limits:
              cpus: "1"
              memory: 150M
        depends_on:
          ${constants.serviceNames.redpanda}:
            condition: service_healthy
        networks:
          - ${constants.network.name}

      # ============================================
      # ClickHouse 25.6 - Using external image for HyperDX compatibility
      # NOTE: ClickHouse 26.x has EXPLAIN ESTIMATE syntax errors with HyperDX
      # NOTE: Official image entrypoint chowns /var/lib/clickhouse, so we use
      #       /etc/clickhouse-server for configs and avoid ro mounts there
      # ============================================
      ${constants.serviceNames.clickhouse}:
        image: ${constants.externalImages.clickhouse}
        container_name: ${constants.containerNames.clickhouse}
        ports:
          - "${toString ports.compose.clickhouseHttp}:${toString ports.services.clickhouseHttp}"
          - "${toString ports.compose.clickhouseNative}:${toString ports.services.clickhouseNative}"
        volumes:
          - clickhouse-data:/var/lib/clickhouse
          - ${gdp.kafkaConfig}/kafka.xml:/etc/clickhouse-server/config.d/kafka.xml:ro
          - ${clickhouseUsersConfig}:/etc/clickhouse-server/users.d/default-allow-all.xml:ro
          # GDP protobuf schemas for Kafka engine
          - ${gdp.formatSchemas}:/var/lib/clickhouse/format_schemas:ro
        environment:
          - CLICKHOUSE_DB=${constants.databases.otelLogs}
        healthcheck:
          test: ["CMD", "clickhouse-client", "--query", "SELECT 1"]
          interval: 5s
          timeout: 5s
          retries: 10
        depends_on:
          ${constants.serviceNames.redpanda}:
            condition: service_healthy
        networks:
          - ${constants.network.name}

      # ============================================
      # ClickHouse - Nix-built (DISABLED: 26.x incompatible with HyperDX)
      # ============================================
      # ${constants.serviceNames.clickhouse}:
      #   image: clickhouse:latest
      #   container_name: ${constants.containerNames.clickhouse}
      #   ports:
      #     - "${toString ports.compose.clickhouseHttp}:${toString ports.services.clickhouseHttp}"
      #     - "${toString ports.compose.clickhouseNative}:${toString ports.services.clickhouseNative}"
      #   volumes:
      #     - clickhouse-data:/var/lib/clickhouse
      #     - ${gdp.formatSchemas}:/var/lib/clickhouse/format_schemas:ro
      #     - ${gdp.kafkaConfig}/kafka.xml:/opt/clickhouse-config/kafka.xml:ro
      #   environment:
      #     - CLICKHOUSE_DB=${constants.databases.otelLogs}
      #   healthcheck:
      #     test: ["CMD", "clickhouse-client", "--query", "SELECT 1"]
      #     interval: 5s
      #     timeout: 5s
      #     retries: 10
      #   depends_on:
      #     ${constants.serviceNames.redpanda}:
      #       condition: service_healthy
      #   networks:
      #     - ${constants.network.name}

      ${constants.serviceNames.fluentbit}:
        image: fluent/fluent-bit:latest
        container_name: ${constants.containerNames.fluentbit}
        ports:
          - "${toString ports.services.fluentbitMetrics}:${toString ports.services.fluentbitMetrics}"
        volumes:
          - ${fluentbitConf}:/fluent-bit/etc/fluent-bit.conf:ro
          - ${fluentbitParsers}:/fluent-bit/etc/parsers.conf:ro
          - ${luaTransform}:/fluent-bit/etc/transform.lua:ro
          # Mount Docker container logs for tail input
          - /home/das/docker/containers:/home/das/docker/containers:ro
        depends_on:
          ${constants.serviceNames.clickhouse}:
            condition: service_healthy
        networks:
          - ${constants.network.name}

      # ============================================
      # OTel Collector - Method 2 (OTLP Direct) + Method 3 (Filelog)
      # ============================================
      ${constants.serviceNames.otelCollector}:
        image: ${constants.externalImages.otelCollector}
        container_name: ${constants.containerNames.otelCollector}
        # Run as root (UID 0) to read Docker container logs
        user: "0"
        volumes:
          - ${otelCollectorConfig}:/etc/otelcol-contrib/config.yaml:ro
          # Mount Docker container logs for filelog receiver (Method 3)
          - /home/das/docker/containers:/home/das/docker/containers:ro
        ports:
          - "${toString ports.compose.clickstackOtlpGrpc}:4317"
          - "${toString ports.compose.clickstackOtlpHttp}:4318"
        depends_on:
          ${constants.serviceNames.clickhouse}:
            condition: service_healthy
        networks:
          - ${constants.network.name}

      ${constants.serviceNames.loggen}:
        image: loggen:latest
        container_name: ${constants.containerNames.loggen}
        environment:
          - LOGGEN_MAX_NUMBER=100
          - LOGGEN_NUM_STRINGS=10
          - LOGGEN_SLEEP_DURATION=5s
          - LOGGEN_HEALTH_PORT=${toString ports.services.loggenHealth}
        ports:
          - "${toString ports.services.loggenHealth}:${toString ports.services.loggenHealth}"
        # Use json-file logging driver so both FluentBit and OTel Collector
        # filelog receiver can read the container logs
        logging:
          driver: json-file
          options:
            max-size: "10m"
            max-file: "3"
        depends_on:
          - ${constants.serviceNames.fluentbit}
        networks:
          - ${constants.network.name}

      # ============================================
      # ClickStack (HyperDX UI only)
      # Official ClickHouse observability UI - we use standalone OTel Collector
      # https://clickhouse.com/docs/use-cases/observability/clickstack
      # ============================================
      ${constants.serviceNames.clickstack}:
        image: ${constants.externalImages.clickstack}
        container_name: ${constants.containerNames.clickstack}
        # Override entrypoint to patch entry.sh and enable local app mode
        entrypoint: ["/bin/sh", "-c", "sed -i 's/REQUIRED_AUTH/DANGEROUSLY_is_local_app_mode💀/g' /etc/local/entry.sh && exec /bin/sh /etc/local/entry.sh"]
        environment:
          # Connect to external ClickHouse (not the bundled one)
          - CLICKHOUSE_ENDPOINT=http://${constants.serviceNames.clickhouse}:${toString ports.services.clickhouseHttp}
          - CLICKHOUSE_USER=default
          - CLICKHOUSE_PASSWORD=
        ports:
          # Only expose the UI port - OTel Collector handles OTLP ingestion separately
          - "${toString ports.compose.clickstackUi}:${toString ports.services.clickstackUi}"
        depends_on:
          ${constants.serviceNames.clickhouse}:
            condition: service_healthy
        networks:
          - ${constants.network.name}

    networks:
      ${constants.network.name}:
        driver: ${constants.network.driver}

    volumes:
      clickhouse-data:
      redpanda-data:
  '';

  # ClickHouse init SQL
  clickhouseInit = writeText "init.sql" ''
    -- HyperDX compatible OTel logs schema with custom loggen fields
    CREATE TABLE IF NOT EXISTS default.otel_logs (
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
        -- Custom fields from loggen for dashboards
        RandomNumber UInt32 DEFAULT 0,
        RandomString LowCardinality(String) CODEC(ZSTD(1)),
        Count UInt64 DEFAULT 0,
        -- Method column (deprecated - use Body content for pipeline identification)
        -- Kept with DEFAULT for backward compatibility
        -- Query by: Body LIKE '%FluentBit%', Body LIKE '%OTLP direct%', Body LIKE '%filelog receiver%'
        Method LowCardinality(String) DEFAULT 'unknown' CODEC(ZSTD(1)),
        -- Ingestion timestamp for latency measurement
        IngestionTimestamp DateTime64(9) DEFAULT now64(9),
        INDEX idx_trace_id TraceId TYPE bloom_filter(0.001) GRANULARITY 1,
        INDEX idx_lower_body lower(Body) TYPE tokenbf_v1(32768, 3, 0) GRANULARITY 8,
        INDEX idx_random_string RandomString TYPE set(100) GRANULARITY 4
    )
    ENGINE = MergeTree
    PARTITION BY toDate(TimestampTime)
    PRIMARY KEY (ServiceName, TimestampTime)
    ORDER BY (ServiceName, TimestampTime, Timestamp)
    TTL TimestampTime + INTERVAL 7 DAY
    SETTINGS index_granularity = 8192, ttl_only_drop_parts = 1;
  '';

  # Script to run docker-compose up
  composeUp = pkgs.writeShellApplication {
    name = "compose-up";
    runtimeInputs = [ pkgs.docker-compose ];
    text = ''
      # Check if loggen image exists (optional, uses Nix-built version)
      if ! docker image inspect loggen:latest >/dev/null 2>&1; then
        echo "Note: loggen image not found. Run 'nix run .#load-images' first to use the Nix-built loggen."
        echo "      Or the stack will start without loggen."
      fi

      echo "Starting OTel demo stack..."
      docker compose -f ${composeFile} up -d

      echo ""
      echo "=============================================="
      echo "  OTel Demo Stack Started (Docker Compose)"
      echo "=============================================="
      echo ""
      echo "ACCESS POINTS:"
      echo "  ClickStack UI:      http://localhost:${toString ports.compose.clickstackUi}"
      echo "  OTLP gRPC:          localhost:${toString ports.compose.clickstackOtlpGrpc}"
      echo "  OTLP HTTP:          http://localhost:${toString ports.compose.clickstackOtlpHttp}"
      echo "  ClickHouse HTTP:    http://localhost:${toString ports.compose.clickhouseHttp}"
      echo "  Redpanda Console:   http://localhost:${toString ports.compose.redpandaConsole}"
      echo "  Redpanda Kafka:     localhost:${toString ports.compose.redpandaKafka}"
      echo "  GDP Prometheus:     http://localhost:${toString ports.compose.gdpPrometheus}/metrics"
      echo ""
      echo "FIRST-TIME SETUP:"
      echo "  nix run .#compose-setup    # Create ClickHouse tables"
      echo ""
      echo "VIEW LOGS:"
      echo "  docker logs -f ${constants.containerNames.loggen}"
      echo "  docker logs -f ${constants.containerNames.gdp}"
      echo ""
      echo "QUERY CLICKHOUSE:"
      echo "  # Count OTel logs"
      echo "  curl 'http://localhost:${toString ports.compose.clickhouseHttp}/?query=SELECT+count()+FROM+otel_logs'"
      echo ""
      echo "  # Count GDP metrics"
      echo "  curl 'http://localhost:${toString ports.compose.clickhouseHttp}/?query=SELECT+count()+FROM+${constants.databases.gdp}.ProtobufSingle'"
      echo ""
      echo "  # View recent logs"
      echo "  curl 'http://localhost:${toString ports.compose.clickhouseHttp}/?query=SELECT+*+FROM+otel_logs+ORDER+BY+Timestamp+DESC+LIMIT+5+FORMAT+Pretty'"
      echo ""
      echo "  # Interactive CLI"
      echo "  docker exec -it ${constants.containerNames.clickhouse} clickhouse-client"
      echo ""
      echo "REDPANDA HEALTH:"
      echo "  docker exec ${constants.containerNames.redpanda} rpk cluster health"
      echo ""
      echo "LIFECYCLE COMMANDS:"
      echo "  nix run .#compose-ps           # Check status"
      echo "  nix run .#compose-logs         # View all logs"
      echo "  nix run .#compose-down         # Stop gracefully"
      echo "  nix run .#compose-force-stop   # Force stop"
      echo ""
    '';
  };

  # Script to run docker-compose down
  composeDown = pkgs.writeShellApplication {
    name = "compose-down";
    runtimeInputs = [ pkgs.docker-compose ];
    text = ''
      echo "Stopping OTel demo stack..."
      docker compose -f ${composeFile} down
    '';
  };

  # Script to view logs
  composeLogs = pkgs.writeShellApplication {
    name = "compose-logs";
    runtimeInputs = [ pkgs.docker-compose ];
    text = ''
      docker compose -f ${composeFile} logs -f "$@"
    '';
  };

  # Script to run docker-compose ps
  composePs = pkgs.writeShellApplication {
    name = "compose-ps";
    runtimeInputs = [ pkgs.docker-compose ];
    text = ''
      docker compose -f ${composeFile} ps
    '';
  };

  # Script to force stop docker-compose (aggressive cleanup)
  composeForceStop = pkgs.writeShellApplication {
    name = "compose-force-stop";
    runtimeInputs = [ pkgs.docker ];
    text = ''
      cd "$(dirname ${composeFile})"
      echo "Force stopping Docker Compose stack..."
      docker compose -f ${composeFile} down --remove-orphans --volumes --timeout 0 || true
      docker compose -f ${composeFile} kill || true
      echo "Force stop complete."
    '';
  };

  # Dashboard JSON for loggen metrics
  dashboardJson = pkgs.writeText "loggen-dashboard.json" (builtins.toJSON {
    name = "Loggen Metrics";
    tiles = [
      {
        name = "RandomString Distribution";
        x = 0;
        y = 0;
        w = 12;
        h = 4;
        series = [{
          type = "table";
          aggFn = "count";
          where = "";
          whereLanguage = "lucene";
          groupBy = [ "RandomString" ];
          sortOrder = "desc";
        }];
      }
      {
        name = "RandomNumber Over Time";
        x = 12;
        y = 0;
        w = 12;
        h = 4;
        series = [{
          type = "time";
          aggFn = "avg";
          field = "RandomNumber";
          where = "RandomNumber:>0";
          whereLanguage = "lucene";
          groupBy = [ ];
          displayType = "line";
        }];
      }
      {
        name = "RandomNumber by RandomString";
        x = 0;
        y = 4;
        w = 12;
        h = 4;
        series = [{
          type = "table";
          aggFn = "avg";
          field = "RandomNumber";
          where = "";
          whereLanguage = "lucene";
          groupBy = [ "RandomString" ];
          sortOrder = "desc";
        }];
      }
      {
        name = "Log Count Over Time";
        x = 12;
        y = 4;
        w = 12;
        h = 4;
        series = [{
          type = "time";
          aggFn = "count";
          where = "";
          whereLanguage = "lucene";
          groupBy = [ ];
          displayType = "line";
        }];
      }
    ];
    tags = [ "loggen" "demo" ];
  });

  # Script to setup ClickHouse tables (ClickStack handles UI config automatically)
  composeSetup = pkgs.writeShellApplication {
    name = "compose-setup";
    runtimeInputs = [ pkgs.curl pkgs.docker ];
    text = ''
      set -euo pipefail

      CLICKHOUSE_URL="http://localhost:${toString ports.compose.clickhouseHttp}"
      CLICKSTACK_URL="http://localhost:${toString ports.compose.clickstackUi}"

      # ============================================
      # 1. Setup ClickHouse Tables
      # ============================================
      echo "Setting up ClickHouse tables..."

      # Wait for ClickHouse to be ready
      echo "Waiting for ClickHouse..."
      for i in {1..30}; do
        if curl -s "$CLICKHOUSE_URL/?query=SELECT+1" 2>/dev/null | grep -q "1"; then
          echo "ClickHouse is ready"
          break
        fi
        echo "  Waiting... ($i/30)"
        sleep 2
      done

      # Create OTel logs table and GDP database/tables (idempotent)
      echo "Creating ClickHouse tables..."
      cat ${clickhouseInit} | docker exec -i ${constants.containerNames.clickhouse} clickhouse-client --multiquery
      cat ${gdp.gdpInitSql} | docker exec -i ${constants.containerNames.clickhouse} clickhouse-client --multiquery
      echo "ClickHouse tables created successfully"

      # ============================================
      # 2. Wait for ClickStack
      # ============================================
      echo ""
      echo "Waiting for ClickStack UI..."
      for i in {1..30}; do
        if curl -s "$CLICKSTACK_URL" >/dev/null 2>&1; then
          echo "ClickStack UI is ready"
          break
        fi
        echo "  Waiting... ($i/30)"
        sleep 2
      done

      echo ""
      echo "Setup complete!"
      echo "  - OTel Logs: default.otel_logs (MergeTree)"
      echo "  - GDP Tables: ${constants.databases.gdp}.ProtobufSingle (MergeTree + Kafka + MV)"
      echo ""
      echo "Open ClickStack UI: $CLICKSTACK_URL"
      echo "Configure data source via Team Settings in the UI"
    '';
  };

in
{
  inherit composeFile composeUp composeDown composeLogs composePs composeForceStop composeSetup dashboardJson;
}
