# nix/lifecycle/constants.nix
#
# Lifecycle testing configuration for ClickHouse OTel demo.
# Centralized configuration for timeouts, services, and phases.
#
# This file provides:
# - Per-variant timeout configurations
# - Service and container lists for verification
# - Phase descriptions and expected outputs
# - Polling intervals and retry settings
#
# NOTE: Uses minikube configuration from nix/constants.nix for consistency.
#
{ }:
let
  ports = import ../ports.nix;
  mainConstants = import ../constants.nix { pkgs = null; };
  minikubeConfig = mainConstants.minikube;
in
rec {
  # Re-export relevant main constants
  inherit (mainConstants) serviceNames containerNames databases kafkaTopics;

  # ─── Variant Definitions ──────────────────────────────────────────────
  # Each variant defines deployment-specific configuration.
  #
  variants = {
    docker-compose = {
      description = "Docker Compose local stack";
      # Services to verify (container names)
      services = [
        "otel-clickhouse"
        "otel-fluentbit"
        "otel-loggen"
        "otel-hyperdx"
        "otel-mongodb"
        "otel-redpanda"
        "otel-gdp"
      ];
      # ClickHouse endpoint for this variant
      clickhouseUrl = "http://localhost:${toString ports.compose.clickhouseHttp}";
      hyperdxApiUrl = "http://localhost:${toString ports.compose.hyperdxApi}";
    };

    minikube = {
      description = "Host Minikube cluster";
      # Pods ordered by startup dependencies:
      # 1. Databases (clickhouse, mongodb, redpanda)
      # 2. Logging infrastructure (otel-collector, fluentbit)
      # 3. Applications (loggen, hyperdx, gdp)
      pods = [
        # Databases
        { label = "app=clickhouse"; name = "clickhouse"; }
        { label = "app=mongodb"; name = "mongodb"; }
        { label = "app=redpanda"; name = "redpanda"; }
        # Logging infrastructure
        { label = "app=otel-collector"; name = "otel-collector"; }
        { label = "app=fluentbit"; name = "fluentbit"; }
        # Applications
        { label = "app=loggen"; name = "loggen"; }
        { label = "app=hyperdx"; name = "hyperdx"; }
        { label = "app=gdp"; name = "gdp"; }
      ];
      # Use namespace from centralized config
      namespace = minikubeConfig.namespace;
    };

    microvm = {
      description = "MicroVM with embedded Minikube";
      # Same dependency order as minikube (accessed via SSH)
      pods = [
        # Databases
        { label = "app=clickhouse"; name = "clickhouse"; }
        { label = "app=mongodb"; name = "mongodb"; }
        { label = "app=redpanda"; name = "redpanda"; }
        # Logging infrastructure
        { label = "app=otel-collector"; name = "otel-collector"; }
        { label = "app=fluentbit"; name = "fluentbit"; }
        # Applications
        { label = "app=loggen"; name = "loggen"; }
        { label = "app=hyperdx"; name = "hyperdx"; }
        { label = "app=gdp"; name = "gdp"; }
      ];
      # Use namespace from centralized config
      namespace = minikubeConfig.namespace;
      # SSH configuration
      sshPort = ports.hostForwards.ssh;
      sshPassword = "demo";
      sshUser = "root";
    };
  };

  # ─── Timeout Configuration ──────────────────────────────────────────────
  # Per-variant timeouts (in seconds) for each phase.
  # Docker Compose is fastest, MicroVM is slowest.
  #
  timeouts = {
    docker-compose = {
      build = 120;       # Building containers
      start = 30;        # docker compose up
      servicesReady = 120; # All containers running
      applicationReady = 60; # ClickHouse tables, logs flowing
      shutdown = 30;     # docker compose down
      waitExit = 30;     # Containers stopped
    };

    minikube = {
      build = 300;       # Building images
      start = 120;       # minikube start
      imageLoad = 180;   # Loading images into minikube
      servicesReady = 180; # All pods ready
      applicationReady = 120; # ClickHouse tables, logs flowing
      shutdown = 60;     # minikube delete
      waitExit = 60;     # Cluster gone
    };

    microvm = {
      build = 300;       # Building MicroVM
      start = 60;        # QEMU start
      serialReady = 30;  # Phase 2a: Wait for serial console (ttyS0)
      virtioReady = 45;  # Phase 2b: Wait for virtio console (hvc0, needs drivers)
      sshReady = 300;    # SSH accessible (boot time)
      minikubeReady = 600; # Minikube inside VM
      servicesReady = 300; # All pods ready inside VM
      applicationReady = 180; # ClickHouse tables, logs flowing
      shutdown = 60;     # poweroff
      waitExit = 120;    # QEMU exited
    };
  };

  # ─── Polling Configuration ──────────────────────────────────────────────
  # How often to poll and retry during waits.
  #
  polling = {
    interval = 2;        # Seconds between polls (default)
    fastInterval = 1;    # For quick checks
    slowInterval = 5;    # For slow operations
    maxRetries = 60;     # Maximum retry attempts
  };

  # ─── Phase Definitions ────────────────────────────────────────────────
  # Human-readable descriptions for each lifecycle phase.
  # Phase numbers are consistent across variants.
  # MicroVM uses sub-phases 2a/2b/2c for progressive boot validation.
  #
  phases = {
    "0" = { name = "Build"; description = "Build images or VM"; };
    "1" = { name = "Start"; description = "Start deployment"; };
    "2" = { name = "Console Ready"; description = "Console or SSH accessible"; };
    "2a" = { name = "Serial Console"; description = "Serial console (ttyS0) accessible"; };
    "2b" = { name = "Virtio Console"; description = "Virtio console (hvc0) accessible"; };
    "2c" = { name = "SSH Ready"; description = "SSH accessible and authenticated"; };
    "2d" = { name = "Minikube Ready"; description = "Minikube running inside VM"; };
    "3" = { name = "Services Ready"; description = "All services/pods running"; };
    "4" = { name = "Application Ready"; description = "ClickHouse tables exist, logs flowing"; };
    "5" = { name = "Shutdown"; description = "Stop deployment"; };
    "6" = { name = "Wait Exit"; description = "Wait for clean exit"; };
  };

  # ─── Application Checks ──────────────────────────────────────────────
  # ClickHouse queries and application-level checks.
  #
  checks = {
    clickhouse = {
      # Basic connectivity check
      ready = "SELECT 1";
      # OTel logs table exists
      otelLogsTable = "SELECT count() FROM system.tables WHERE database='default' AND name='otel_logs'";
      # Log count query
      logCount = "SELECT count() FROM otel_logs";
      # Recent logs (last minute)
      recentLogs = "SELECT count() FROM otel_logs WHERE Timestamp > now() - INTERVAL 1 MINUTE";
      # Logs by pipeline (FluentBit, OTLP, Filelog)
      # Note: No time filter - for deployment verification, we check existence not recency
      fluentbitLogs = "SELECT count() FROM otel_logs WHERE Body LIKE '%FluentBit%'";
      otlpLogs = "SELECT count() FROM otel_logs WHERE Body LIKE '%OTLP direct%'";
      filelogLogs = "SELECT count() FROM otel_logs WHERE Body LIKE '%filelog receiver%'";
    };

    gdp = {
      # GDP table exists
      tableExists = "SELECT count() FROM system.tables WHERE database='gdp' AND name='ProtobufSingle'";
      # GDP metrics count
      metricCount = "SELECT count() FROM gdp.ProtobufSingle";
      # Kafka consumer status (no exceptions)
      kafkaHealthy = "SELECT countIf(length(exceptions.text)>0) FROM system.kafka_consumers";
    };

    hyperdx = {
      # Health endpoint
      healthPath = "/health";
      healthExpected = "OK";
    };
  };

  # ─── Terminal Formatting ──────────────────────────────────────────────
  # ANSI color codes for terminal output.
  #
  colors = {
    reset = "\\033[0m";
    bold = "\\033[1m";
    red = "\\033[31m";
    green = "\\033[32m";
    yellow = "\\033[33m";
    blue = "\\033[34m";
    cyan = "\\033[36m";
    magenta = "\\033[35m";
  };

  # ─── Expect Script Configuration ──────────────────────────────────────
  # Configuration for expect scripts that interact with MicroVM console.
  #
  expect = {
    # Shell prompt pattern (NixOS root prompt)
    shellPromptPattern = "root@.*:.*#";

    # Boot completion marker
    bootCompletePattern = "Reached target.*Multi-User System|Welcome to NixOS";

    # Default username and password for MicroVM
    username = "root";
    password = "demo";

    # Timeout for expect operations (seconds)
    defaultTimeout = 30;

    # Time to wait between sending characters (milliseconds)
    sendDelay = 50;
  };

  # ─── Debug Configuration ──────────────────────────────────────────────
  # Settings for debug mode (LIFECYCLE_DEBUG=1).
  #
  debug = {
    # Show full command output
    verbose = true;
    # Capture logs on failure
    captureLogs = true;
    # Keep deployment running on failure for inspection
    keepOnFailure = false;
  };
}
