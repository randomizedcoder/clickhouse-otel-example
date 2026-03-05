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

    # MongoDB (HyperDX session storage)
    mongodb = 27017;

    # HyperDX
    hyperdxApi = 8000;
    hyperdxApp = 8080;

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
    hyperdxApi = 28000;
    hyperdxApp = 28080;
    clickhouseHttp = 28123;
    clickhouseNative = 29000;
    mongodb = 27017; # Standard port, unlikely to conflict
    # NodePort forwards (via minikube tunnel on VM localhost)
    hyperdxApiNodePort = 30800;
    hyperdxAppNodePort = 30808;
  };

  # ============================================
  # Kubernetes NodePorts
  # ============================================
  nodePorts = {
    hyperdxApi = 30800;
    hyperdxApp = 30808;
  };

  # ============================================
  # Docker Compose External Ports
  # Using 3XXXX prefix to avoid conflicts with local services
  # ============================================
  compose = {
    hyperdxApi = 38000;
    hyperdxApp = 38080;
    mongodb = 37017;
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
