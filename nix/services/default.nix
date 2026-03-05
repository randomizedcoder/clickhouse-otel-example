# nix/services/default.nix
#
# Service definitions for the OTel demo stack.
# All services are defined using the types from types.nix.
# These definitions are used to generate both Docker Compose and K8s manifests.
#
{ pkgs, lib }:
let
  ports = import ../ports.nix;
  constants = import ../constants.nix { inherit pkgs; };
  types = import ./types.nix { inherit lib; };

  # Helper to create environment variable from constant
  mkEnv = name: value: { inherit name value; };

  # ─── ClickHouse Service ────────────────────────────────────────────────────
  clickhouse = types.mkService {
    name = constants.serviceNames.clickhouse;
    image = "clickhouse:latest";
    workloadType = "StatefulSet";

    ports = [
      (types.mkPort {
        name = "http";
        containerPort = ports.services.clickhouseHttp;
        hostPort = ports.compose.clickhouseHttp;
      })
      (types.mkPort {
        name = "native";
        containerPort = ports.services.clickhouseNative;
        hostPort = ports.compose.clickhouseNative;
      })
    ];

    env = {
      CLICKHOUSE_DB = constants.databases.otelLogs;
    };

    volumes = [
      (types.mkVolume {
        name = "data";
        mountPath = "/var/lib/clickhouse";
      })
      (types.mkVolume {
        name = "format-schemas";
        mountPath = "/var/lib/clickhouse/format_schemas";
        readOnly = true;
      })
      (types.mkVolume {
        name = "kafka-config";
        mountPath = "/opt/clickhouse-config/kafka.xml";
        readOnly = true;
      })
    ];

    healthCheck = types.mkHealthCheck {
      type = "exec";
      command = [ "clickhouse-client" "--query" "SELECT 1" ];
      interval = 5;
      timeout = 5;
      retries = 10;
    };

    dependsOn = [ constants.serviceNames.redpanda ];
  };

  # ─── MongoDB Service ───────────────────────────────────────────────────────
  mongodb = types.mkService {
    name = constants.serviceNames.mongodb;
    image = "mongo:7";
    workloadType = "StatefulSet";

    ports = [
      (types.mkPort {
        name = "mongo";
        containerPort = ports.services.mongodb;
        hostPort = ports.compose.mongodb;
      })
    ];

    volumes = [
      (types.mkVolume {
        name = "data";
        mountPath = "/data/db";
      })
    ];

    healthCheck = types.mkHealthCheck {
      type = "exec";
      command = [ "mongosh" "--eval" "db.adminCommand('ping')" ];
      interval = 5;
      timeout = 5;
      retries = 10;
    };
  };

  # ─── Redpanda Service ──────────────────────────────────────────────────────
  redpanda = types.mkService {
    name = constants.serviceNames.redpanda;
    image = constants.externalImages.redpanda;
    workloadType = "StatefulSet";

    command = [ "redpanda" "start" ];
    args = [
      "--kafka-addr=internal://0.0.0.0:${toString ports.services.redpandaKafkaInternal},external://0.0.0.0:${toString ports.services.redpandaKafkaExternal}"
      "--advertise-kafka-addr=internal://${constants.serviceNames.redpanda}:${toString ports.services.redpandaKafkaInternal},external://localhost:${toString ports.services.redpandaKafkaExternal}"
      "--schema-registry-addr=internal://0.0.0.0:${toString ports.services.redpandaSchemaRegistryInternal},external://0.0.0.0:${toString ports.services.redpandaSchemaRegistryExternal}"
      "--rpc-addr=${constants.serviceNames.redpanda}:${toString ports.services.redpandaRpc}"
      "--advertise-rpc-addr=${constants.serviceNames.redpanda}:${toString ports.services.redpandaRpc}"
      "--mode=dev-container"
      "--smp=1"
      "--default-log-level=info"
    ];

    ports = [
      (types.mkPort {
        name = "kafka";
        containerPort = ports.services.redpandaKafkaInternal;
        hostPort = ports.compose.redpandaKafka;
      })
      (types.mkPort {
        name = "schema-registry";
        containerPort = ports.services.redpandaSchemaRegistryExternal;
        hostPort = ports.compose.redpandaSchemaRegistry;
      })
    ];

    volumes = [
      (types.mkVolume {
        name = "data";
        mountPath = "/var/lib/redpanda/data";
      })
    ];

    healthCheck = types.mkHealthCheck {
      type = "exec";
      command = [ "rpk" "cluster" "health" ];
      interval = 10;
      timeout = 5;
      retries = 5;
    };
  };

  # ─── Redpanda Console Service ──────────────────────────────────────────────
  redpandaConsole = types.mkService {
    name = constants.serviceNames.redpandaConsole;
    image = constants.externalImages.redpandaConsole;
    workloadType = "Deployment";

    ports = [
      (types.mkPort {
        name = "http";
        containerPort = ports.services.redpandaConsole;
        hostPort = ports.compose.redpandaConsole;
      })
    ];

    env = {
      CONFIG_FILEPATH = "/tmp/config.yml";
    };

    dependsOn = [ constants.serviceNames.redpanda ];
  };

  # ─── FluentBit Service ─────────────────────────────────────────────────────
  fluentbit = types.mkService {
    name = constants.serviceNames.fluentbit;
    image = "fluent/fluent-bit:latest";
    workloadType = "DaemonSet";

    ports = [
      (types.mkPort {
        name = "metrics";
        containerPort = ports.services.fluentbitMetrics;
      })
      (types.mkPort {
        name = "forward";
        containerPort = 24224;
      })
    ];

    volumes = [
      (types.mkVolume {
        name = "config";
        mountPath = "/fluent-bit/etc/fluent-bit.conf";
        readOnly = true;
      })
      (types.mkVolume {
        name = "parsers";
        mountPath = "/fluent-bit/etc/parsers.conf";
        readOnly = true;
      })
      (types.mkVolume {
        name = "lua";
        mountPath = "/fluent-bit/etc/transform.lua";
        readOnly = true;
      })
    ];

    dependsOn = [ constants.serviceNames.clickhouse ];
  };

  # ─── Loggen Service ────────────────────────────────────────────────────────
  loggen = types.mkService {
    name = constants.serviceNames.loggen;
    image = "loggen:latest";
    workloadType = "Deployment";

    ports = [
      (types.mkPort {
        name = "health";
        containerPort = ports.services.loggenHealth;
      })
    ];

    env = {
      LOGGEN_MAX_NUMBER = "100";
      LOGGEN_NUM_STRINGS = "10";
      LOGGEN_SLEEP_DURATION = "5s";
      LOGGEN_HEALTH_PORT = toString ports.services.loggenHealth;
    };

    healthCheck = types.mkHealthCheck {
      type = "http";
      path = "/health";
      port = "health";
      interval = 10;
      timeout = 5;
      retries = 3;
    };

    dependsOn = [ constants.serviceNames.fluentbit ];
  };

  # ─── HyperDX Service ───────────────────────────────────────────────────────
  hyperdx = types.mkService {
    name = constants.serviceNames.hyperdx;
    image = "hyperdx/hyperdx:latest";
    workloadType = "Deployment";

    ports = [
      (types.mkPort {
        name = "api";
        containerPort = ports.services.hyperdxApi;
        hostPort = ports.compose.hyperdxApi;
        nodePort = ports.nodePorts.hyperdxApi;
      })
      (types.mkPort {
        name = "ui";
        containerPort = ports.services.hyperdxApp;
        hostPort = ports.compose.hyperdxApp;
        nodePort = ports.nodePorts.hyperdxApp;
      })
    ];

    env = {
      CLICKHOUSE_HOST = constants.serviceNames.clickhouse;
      CLICKHOUSE_PORT = toString ports.services.clickhouseHttp;
      CLICKHOUSE_USER = "default";
      CLICKHOUSE_PASSWORD = "";
      HYPERDX_API_PORT = toString ports.services.hyperdxApi;
      HYPERDX_APP_PORT = toString ports.services.hyperdxApp;
    };

    healthCheck = types.mkHealthCheck {
      type = "http";
      path = "/health";
      port = "api";
      interval = 30;
      timeout = 10;
      retries = 3;
    };

    resources = types.mkResources {
      cpus = "1";
      memory = "1Gi";
      cpuRequest = "250m";
      memoryRequest = "512Mi";
    };

    dependsOn = [
      constants.serviceNames.clickhouse
      constants.serviceNames.mongodb
    ];
  };

  # ─── GDP Service ───────────────────────────────────────────────────────────
  gdp = types.mkService {
    name = constants.serviceNames.gdp;
    image = "gdp:latest";
    workloadType = "Deployment";

    args = [
      "-dest=kafka:${constants.serviceNames.redpanda}:${toString ports.services.redpandaKafkaInternal}"
      "-kafkaSchemaUrl=http://${constants.serviceNames.redpanda}:${toString ports.services.redpandaSchemaRegistryInternal}"
      "-frequency=${constants.gdpConfig.pollFrequency}"
      "-timeout=${constants.gdpConfig.pollTimeout}"
      "-d=${constants.gdpConfig.debugLevel}"
    ];

    ports = [
      (types.mkPort {
        name = "prometheus";
        containerPort = ports.services.gdpPrometheus;
        hostPort = ports.compose.gdpPrometheus;
      })
    ];

    volumes = [
      (types.mkVolume {
        name = "proto";
        mountPath = "/prometheus.proto";
        readOnly = true;
      })
      (types.mkVolume {
        name = "protolist";
        mountPath = "/prometheus_protolist.proto";
        readOnly = true;
      })
    ];

    resources = types.mkResources {
      cpus = "1";
      memory = "150M";
    };

    dependsOn = [ constants.serviceNames.redpanda ];
  };

in
{
  # Export all services
  services = {
    inherit clickhouse mongodb redpanda redpandaConsole fluentbit loggen hyperdx gdp;
  };

  # Export service list by category
  byCategory = {
    database = [ clickhouse mongodb redpanda ];
    logging = [ fluentbit ];
    application = [ loggen hyperdx gdp ];
    ui = [ redpandaConsole ];
  };

  # Export ordered list (respecting dependencies)
  ordered = [
    redpanda
    mongodb
    clickhouse
    fluentbit
    redpandaConsole
    loggen
    hyperdx
    gdp
  ];

  # Export types for external use
  inherit types;

  # Re-export constants
  inherit constants ports;
}
