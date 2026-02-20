# Port configuration for the OTel demo stack
# All ports are defined here to ensure consistency across containers, K8s, and MicroVM
{
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

    # HyperDX
    hyperdxApi = 8000;
    hyperdxApp = 8080;

    # SSH (inside VM)
    ssh = 22;
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
  };

  # ============================================
  # Kubernetes NodePorts
  # ============================================
  nodePorts = {
    hyperdxApi = 30800;
    hyperdxApp = 30808;
  };
}
