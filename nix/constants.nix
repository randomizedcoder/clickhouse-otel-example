# Central constants - single source of truth for GDP integration
# All non-port constants are defined here
{ pkgs }:

rec {
  # ============================================
  # Service Names (DNS/networking)
  # ============================================
  serviceNames = {
    clickhouse = "clickhouse";
    mongodb = "mongodb";
    fluentbit = "fluentbit";
    loggen = "loggen";
    hyperdx = "hyperdx";
    redpanda = "redpanda";
    redpandaConsole = "redpanda-console";
    gdp = "gdp";
  };

  # ============================================
  # Docker Container Names
  # ============================================
  containerNames = {
    clickhouse = "otel-clickhouse";
    mongodb = "otel-mongodb";
    fluentbit = "otel-fluentbit";
    loggen = "otel-loggen";
    hyperdx = "otel-hyperdx";
    redpanda = "otel-redpanda";
    redpandaConsole = "otel-redpanda-console";
    gdp = "otel-gdp";
  };

  # ============================================
  # External Images (not built by Nix)
  # ============================================
  externalImages = {
    # Redpanda: Complex C++ Kafka-compatible broker
    redpanda = "docker.redpanda.com/redpandadata/redpanda:v24.3.8";
    # Console: React+Go web UI
    redpandaConsole = "docker.redpanda.com/redpandadata/console:v2.8.4";
    # ClickHouse 25.6: Compatible with HyperDX (26.x has EXPLAIN ESTIMATE syntax issues)
    clickhouse = "clickhouse/clickhouse-server:25.6";
    # HyperDX: Try older 2.x version to avoid EXPLAIN ESTIMATE issues
    hyperdx = "hyperdx/hyperdx:2.6.0";
  };

  # ============================================
  # GDP Source (fetched from GitHub, built by Nix)
  # ============================================
  gdpSource = {
    owner = "randomizedcoder";
    repo = "gdp";
    rev = "main"; # Pin to commit SHA for reproducibility
    hash = "sha256-8NuoIDWdd6YulE8v9OniPHX/06a2cMnhbs+uxt7+ZLs=";
  };

  # ============================================
  # Versions (for Nix-built images)
  # ============================================
  versions = {
    gdp = "1.0.0";
  };

  # ============================================
  # Databases
  # ============================================
  databases = {
    otelLogs = "default";
    gdp = "gdp";
    hyperdx = "hyperdx";
  };

  # ============================================
  # Kafka Topics
  # ============================================
  kafkaTopics = {
    protobufSingle = "ProtobufSingle";
    protobufListProtodelim = "ProtobufListProtodelim";
  };

  # ============================================
  # Retention (days)
  # ============================================
  retention = {
    otelLogs = 7;
    gdpMetrics = 14;
  };

  # ============================================
  # GDP Runtime Config
  # ============================================
  gdpConfig = {
    pollFrequency = "10s";
    pollTimeout = "5s";
    kafkaProduceTimeout = "2s";
    debugLevel = "11";
    goMaxProcs = "2";
  };

  # ============================================
  # Network
  # ============================================
  network = {
    name = "otel-demo";
    driver = "bridge";
  };

  # ============================================
  # Minikube Configuration
  # ============================================
  minikube = {
    # Resource allocation
    resources = {
      cpus = 4;
      memory = "8g";
      memoryMb = 8192;
    };

    # Images to load into minikube (Nix-built)
    # NOTE: hyperdx uses upstream Docker Hub image (hyperdx/hyperdx:latest) for now
    # TODO: Add hyperdx back once Nix build proto file issue is fixed
    imageNames = [
      "loggen"
      "fluentbit"
      "clickhouse"
      "mongodb"
      "otel-collector"
      "gdp"
      "redpanda"
      "redpanda-console"
    ];

    # Kubernetes namespace
    namespace = "otel-demo";

    # Minikube driver
    driver = "docker";

    # Timeouts (seconds)
    timeouts = {
      nodeReady = 120;
      deploymentReady = 300;
      imageLoad = 180;
    };
  };
}
