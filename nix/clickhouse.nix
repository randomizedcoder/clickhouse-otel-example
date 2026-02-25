{ lib
, pkgs
, runCommand
  # Set to true to use minimal ClickHouse build (smaller binary, fewer features)
  # See docs/CLICKHOUSE_SIZE_OPTIMIZATION.md for details
, useMinimal ? false
}:

# ClickHouse package with custom configuration for OTel logs storage
let
  # Import port configuration
  ports = import ./ports.nix;

  # Select ClickHouse package based on useMinimal flag
  clickhouseBase = if useMinimal
    then import ./clickhouse-minimal.nix { inherit pkgs; }
    else pkgs.clickhouse;

  # Configuration options with defaults
  defaultConfig = {
    # Server settings
    httpPort = ports.services.clickhouseHttp;
    tcpPort = ports.services.clickhouseNative;
    interserverPort = ports.services.clickhouseInterserver;
    listenHost = "0.0.0.0";

    # Paths
    dataPath = "/var/lib/clickhouse/";
    tmpPath = "/var/lib/clickhouse/tmp/";
    userFilesPath = "/var/lib/clickhouse/user_files/";

    # User settings
    defaultUser = "default";
    defaultPassword = "";
    allowNetworks = [ "::/0" ];
    accessManagement = true;

    # Resource limits
    maxConnections = 100;
    keepAliveTimeout = 3;
    maxConcurrentQueries = 100;
    maxMemoryUsage = 10000000000;
    markCacheSize = 5368709120;

    # Logging
    logLevel = "information";
    logToConsole = true;
  };

  # Build configuration XML files
  mkConfigDir = config: runCommand "clickhouse-config" { } ''
    mkdir -p $out/opt/clickhouse-config

    # Server configuration
    cat > $out/opt/clickhouse-config/config.xml << 'EOF'
<?xml version="1.0"?>
<clickhouse>
    <logger>
        <level>${config.logLevel}</level>
        <console>${if config.logToConsole then "1" else "0"}</console>
    </logger>

    <http_port>${toString config.httpPort}</http_port>
    <tcp_port>${toString config.tcpPort}</tcp_port>
    <interserver_http_port>${toString config.interserverPort}</interserver_http_port>

    <listen_host>${config.listenHost}</listen_host>

    <path>${config.dataPath}</path>
    <tmp_path>${config.tmpPath}</tmp_path>
    <user_files_path>${config.userFilesPath}</user_files_path>

    <users_config>/opt/clickhouse-config/users.xml</users_config>
    <default_database>default</default_database>

    <mlock_executable>false</mlock_executable>

    <max_connections>${toString config.maxConnections}</max_connections>
    <keep_alive_timeout>${toString config.keepAliveTimeout}</keep_alive_timeout>
    <max_concurrent_queries>${toString config.maxConcurrentQueries}</max_concurrent_queries>

    <mark_cache_size>${toString config.markCacheSize}</mark_cache_size>
</clickhouse>
EOF

    # Users configuration
    cat > $out/opt/clickhouse-config/users.xml << 'EOF'
<?xml version="1.0"?>
<clickhouse>
    <users>
        <${config.defaultUser}>
            <password>${config.defaultPassword}</password>
            <networks>
                ${lib.concatMapStringsSep "\n                " (ip: "<ip>${ip}</ip>") config.allowNetworks}
            </networks>
            <profile>default</profile>
            <quota>default</quota>
            <access_management>${if config.accessManagement then "1" else "0"}</access_management>
        </${config.defaultUser}>
    </users>
    <profiles>
        <default>
            <max_memory_usage>${toString config.maxMemoryUsage}</max_memory_usage>
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

  # Create the configured ClickHouse derivation
  mkClickhouse = configOverrides:
    let
      config = defaultConfig // configOverrides;
      configDir = mkConfigDir config;
    in
    pkgs.symlinkJoin {
      name = if useMinimal then "clickhouse-minimal-configured" else "clickhouse-configured";
      paths = [ clickhouseBase configDir ];

      meta = clickhouseBase.meta // {
        description = "ClickHouse with custom configuration for OTel logs storage"
          + (if useMinimal then " (minimal build)" else "");
      };
    };

in
{
  # Default configuration for container use
  package = mkClickhouse { };

  # Configuration directory for the default setup
  configDir = mkConfigDir defaultConfig;

  # Allow custom configurations
  inherit mkClickhouse defaultConfig;

  # Expose whether minimal build is being used
  inherit useMinimal;

  # Expose the base package (without config) for reference
  basePackage = clickhouseBase;

  # Re-export ports for convenience
  inherit (ports.services) clickhouseHttp clickhouseNative clickhouseInterserver;
}
