# Port configuration for the OTel demo stack
# All ports are defined here to ensure consistency across containers, K8s, and MicroVM
{
  # ============================================
  # Host Configuration (for external URLs)
  # ============================================
  externalHost = "localhost"; # Host used for browser access
  # ============================================
  # Service Ports (inside containers/pods)
  # ============================================
  services = {
    # Loggen health check
    loggenHealth = 8081;

    # FluentBit
    fluentbitMetrics = 2020;

    # ClickHouse
    clickhouseHttp = 8123;
    clickhouseNative = 9000;
    clickhouseInterserver = 9009;

    # MongoDB (for standalone image builds, not used by ClickStack)
    mongodb = 27017;

    # HyperDX (for standalone image builds, not used by ClickStack)
    hyperdxApi = 8000;
    hyperdxApp = 8080;

    # ClickStack (HyperDX + OTel collector)
    clickstackUi = 8080;
    clickstackOtlpGrpc = 4317;
    clickstackOtlpHttp = 4318;

    # SSH (inside VM)
    ssh = 22;

    # GDP Integration - Redpanda (Kafka-compatible)
    redpandaKafkaInternal = 9092;
    redpandaKafkaExternal = 19092;
    redpandaSchemaRegistryInternal = 8081;
    redpandaSchemaRegistryExternal = 18081;
    redpandaAdminApi = 9644;
    redpandaRpc = 33145;
    redpandaConsole = 8080;

    # GDP (Prometheus metrics collector)
    gdpPrometheus = 8888;
  };

  # ============================================
  # Host Forwards (MicroVM -> Host)
  # Using 2XXXX prefix to avoid collisions
  # ============================================
  hostForwards = {
    ssh = 22022;
    fluentbitMetrics = 22020;
    clickstackUi = 28080;
    clickstackOtlpGrpc = 24317;
    clickstackOtlpHttp = 24318;
    clickhouseHttp = 28123;
    clickhouseNative = 29000;
  };

  # ============================================
  # Kubernetes NodePorts
  # ============================================
  nodePorts = {
    clickstackUi = 30808;
    clickstackOtlpGrpc = 30317;
    clickstackOtlpHttp = 30318;
  };

  # ============================================
  # Docker Compose External Ports
  # Using 3XXXX prefix to avoid conflicts with local services
  # ============================================
  compose = {
    clickstackUi = 38090;
    clickstackOtlpGrpc = 34317;
    clickstackOtlpHttp = 34318;
    clickhouseHttp = 38123;
    clickhouseNative = 39000;

    # GDP Integration
    redpandaKafka = 39092;
    redpandaSchemaRegistry = 38081;
    redpandaConsole = 38085;
    gdpPrometheus = 38888;
  };

  # ============================================
  # Host Forwards (MicroVM -> Host) - GDP Integration
  # Using 2XXXX prefix to avoid collisions
  # ============================================
  hostForwardsGdp = {
    redpandaKafka = 29092;
    redpandaSchemaRegistry = 28081;
    redpandaConsole = 28085;
    gdpPrometheus = 28888;
  };

  # ============================================
  # Console Ports for MicroVM Serial Debugging
  # Using 245XX prefix (following pcp pattern)
  # ============================================
  console = {
    serial = 24500;  # ttyS0 - slow, early boot (TCP socket)
    virtio = 24501;  # hvc0 - fast, after drivers (TCP socket)
  };
}
