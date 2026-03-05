# Central constants - single source of truth for GDP integration
# All non-port constants are defined here
{ pkgs }:

rec {
  # ============================================
  # Service Names (DNS/networking)
  # ============================================
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

  # ============================================
  # Docker Container Names
  # ============================================
  containerNames = {
    clickhouse = "otel-clickhouse";
    fluentbit = "otel-fluentbit";
    loggen = "otel-loggen";
    clickstack = "otel-clickstack";
    otelCollector = "otel-collector";
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
    # ClickHouse: Using official image for stability
    clickhouse = "clickhouse/clickhouse-server:latest";
    # ClickStack: Official ClickHouse observability stack (HyperDX + OTel collector)
    # Replaces separate hyperdx container - bundles UI + ingestion
    # https://clickhouse.com/docs/use-cases/observability/clickstack
    clickstack = "clickhouse/clickstack-all-in-one:latest";
    # OTel Collector: Standalone collector for OTLP ingestion
    otelCollector = "otel/opentelemetry-collector-contrib:0.96.0";
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
