{ lib
, pkgs
, dockerTools
, buildEnv
, writeShellScript
, runCommand
, goApp
, fluentbit
, hyperdx
}:

let
  # Import port configuration
  ports = import ./ports.nix;

  # Common labels for all images
  commonLabels = {
    "org.opencontainers.image.vendor" = "clickhouse-otel-example";
    "org.opencontainers.image.licenses" = "MIT";
  };

  # ============================================
  # Loggen Container
  # ============================================
  loggenImage = dockerTools.buildImage {
    name = "loggen";
    tag = "latest";

    # Use scratch as base (empty) - static Go binary needs nothing
    copyToRoot = buildEnv {
      name = "loggen-root";
      paths = [ goApp ];
      pathsToLink = [ "/bin" ];
    };

    config = {
      Entrypoint = [ "/bin/loggen" ];

      Env = [
        "LOGGEN_MAX_NUMBER=100"
        "LOGGEN_NUM_STRINGS=10"
        "LOGGEN_SLEEP_DURATION=5s"
        "LOGGEN_HEALTH_PORT=${toString ports.services.loggenHealth}"
      ];

      ExposedPorts = {
        "${toString ports.services.loggenHealth}/tcp" = { };
      };

      Labels = commonLabels // {
        "org.opencontainers.image.title" = "loggen";
        "org.opencontainers.image.description" = "Log generator for OTel pipeline demo";
      };
    };
  };

  # ============================================
  # FluentBit Container
  # ============================================
  fluentbitImage = dockerTools.buildImage {
    name = "fluentbit";
    tag = "latest";

    # FluentBit needs some basic runtime
    copyToRoot = buildEnv {
      name = "fluentbit-root";
      paths = [
        fluentbit
        pkgs.cacert  # For TLS
        pkgs.tzdata  # Timezone data
      ];
      pathsToLink = [ "/bin" "/etc" "/share" ];
    };

    # Create required directories
    extraCommands = ''
      mkdir -p var/lib/fluent-bit
      mkdir -p var/log
      mkdir -p tmp
    '';

    config = {
      Entrypoint = [ "/bin/fluent-bit" ];
      Cmd = [ "-c" "/etc/fluent-bit/fluent-bit.conf" ];

      Env = [
        "SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt"
        "TZDIR=/share/zoneinfo"
      ];

      ExposedPorts = {
        "${toString ports.services.fluentbitMetrics}/tcp" = { };  # HTTP server / metrics
      };

      Labels = commonLabels // {
        "org.opencontainers.image.title" = "fluent-bit";
        "org.opencontainers.image.description" = "FluentBit with OTel transformation";
      };
    };
  };

  # ============================================
  # ClickHouse Container
  # ============================================
  # Put custom config in /opt to avoid conflicts with nixpkgs clickhouse
  clickhouseConfigDir = runCommand "clickhouse-config" { } ''
    mkdir -p $out/opt/clickhouse-config

    # Server configuration
    cat > $out/opt/clickhouse-config/config.xml << 'EOF'
<?xml version="1.0"?>
<clickhouse>
    <logger>
        <level>information</level>
        <console>1</console>
    </logger>

    <http_port>8123</http_port>
    <tcp_port>9000</tcp_port>
    <interserver_http_port>9009</interserver_http_port>

    <listen_host>0.0.0.0</listen_host>

    <path>/var/lib/clickhouse/</path>
    <tmp_path>/var/lib/clickhouse/tmp/</tmp_path>
    <user_files_path>/var/lib/clickhouse/user_files/</user_files_path>

    <users_config>/opt/clickhouse-config/users.xml</users_config>
    <default_database>default</default_database>

    <mlock_executable>false</mlock_executable>

    <max_connections>100</max_connections>
    <keep_alive_timeout>3</keep_alive_timeout>
    <max_concurrent_queries>100</max_concurrent_queries>

    <mark_cache_size>5368709120</mark_cache_size>
</clickhouse>
EOF

    # Users configuration
    cat > $out/opt/clickhouse-config/users.xml << 'EOF'
<?xml version="1.0"?>
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
    <profiles>
        <default>
            <max_memory_usage>10000000000</max_memory_usage>
            <load_balancing>random</load_balancing>
        </default>
    </profiles>
    <quotas>
        <default>
            <interval>
                <duration>3600</duration>
                <queries>0</queries>
                <errors>0</errors>
                <result_rows>0</result_rows>
                <read_rows>0</read_rows>
                <execution_time>0</execution_time>
            </interval>
        </default>
    </quotas>
</clickhouse>
EOF
  '';

  clickhouseImage = dockerTools.buildImage {
    name = "clickhouse";
    tag = "latest";

    copyToRoot = buildEnv {
      name = "clickhouse-root";
      paths = [
        pkgs.clickhouse
        clickhouseConfigDir
        pkgs.cacert
        pkgs.tzdata
      ];
      pathsToLink = [ "/bin" "/etc" "/share" "/opt" ];
    };

    extraCommands = ''
      mkdir -p var/lib/clickhouse/tmp
      mkdir -p var/lib/clickhouse/user_files
      mkdir -p var/log/clickhouse-server
    '';

    config = {
      Entrypoint = [ "/bin/clickhouse-server" ];
      Cmd = [ "--config-file=/opt/clickhouse-config/config.xml" ];

      Env = [
        "CLICKHOUSE_DB=default"
        "SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt"
        "TZDIR=/share/zoneinfo"
      ];

      ExposedPorts = {
        "${toString ports.services.clickhouseHttp}/tcp" = { };  # HTTP interface
        "${toString ports.services.clickhouseNative}/tcp" = { };  # Native protocol
        "${toString ports.services.clickhouseInterserver}/tcp" = { };  # Interserver
      };

      Volumes = {
        "/var/lib/clickhouse" = { };
      };

      Labels = commonLabels // {
        "org.opencontainers.image.title" = "clickhouse";
        "org.opencontainers.image.description" = "ClickHouse for OTel logs storage";
      };
    };
  };

  # ============================================
  # HyperDX Container
  # ============================================
  hyperdxImage = dockerTools.buildImage {
    name = "hyperdx";
    tag = "latest";

    copyToRoot = buildEnv {
      name = "hyperdx-root";
      paths = [
        hyperdx
        pkgs.nodejs_22
        pkgs.cacert
        pkgs.tzdata
        pkgs.bashInteractive
        pkgs.coreutils
      ];
      pathsToLink = [ "/bin" "/app" "/etc" "/share" ];
    };

    extraCommands = ''
      mkdir -p tmp
      mkdir -p app
    '';

    config = {
      WorkingDir = "/app";
      Entrypoint = [ "${hyperdx}/bin/hyperdx-start" ];

      Env = [
        "NODE_ENV=production"
        "SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt"
        "TZDIR=/share/zoneinfo"
        # HyperDX port settings
        "HYPERDX_API_PORT=${toString ports.services.hyperdxApi}"
        "HYPERDX_APP_PORT=${toString ports.services.hyperdxApp}"
        # ClickHouse connection (will be overridden by K8s env)
        "CLICKHOUSE_HOST=clickhouse"
        "CLICKHOUSE_PORT=${toString ports.services.clickhouseHttp}"
        # Disable auth for demo
        "HYPERDX_AUTH_DISABLED=true"
      ];

      ExposedPorts = {
        "${toString ports.services.hyperdxApi}/tcp" = { };  # API
        "${toString ports.services.hyperdxApp}/tcp" = { };  # Frontend
      };

      Labels = commonLabels // {
        "org.opencontainers.image.title" = "hyperdx";
        "org.opencontainers.image.description" = "HyperDX observability platform";
      };
    };
  };

  # ============================================
  # Helper Scripts
  # ============================================
  loadScript = writeShellScript "load-images" ''
    set -e
    echo "Loading container images into Docker..."

    echo "Loading loggen..."
    ${pkgs.docker}/bin/docker load < ${loggenImage}

    echo "Loading fluentbit..."
    ${pkgs.docker}/bin/docker load < ${fluentbitImage}

    echo "Loading clickhouse..."
    ${pkgs.docker}/bin/docker load < ${clickhouseImage}

    echo "Loading hyperdx..."
    ${pkgs.docker}/bin/docker load < ${hyperdxImage}

    echo ""
    echo "Images loaded successfully:"
    ${pkgs.docker}/bin/docker images | grep -E "(loggen|fluentbit|clickhouse|hyperdx)" || true
  '';

  # Bundle all images
  allImages = runCommand "all-images" { } ''
    mkdir -p $out
    cp ${loggenImage} $out/loggen.tar.gz
    cp ${fluentbitImage} $out/fluentbit.tar.gz
    cp ${clickhouseImage} $out/clickhouse.tar.gz
    cp ${hyperdxImage} $out/hyperdx.tar.gz
  '';

in
{
  inherit loggenImage fluentbitImage clickhouseImage hyperdxImage;
  inherit loadScript allImages;
}
