{ lib
, pkgs
, runCommand
, fluent-bit
}:

# FluentBit package with parameterized configuration
let
  # Import port configuration
  ports = import ./ports.nix;

  # Base FluentBit from nixpkgs
  fluentbitBase = fluent-bit;

  # Default configuration options
  defaultConfig = {
    # Service settings
    flushInterval = 2; # Production recommendation: 2-5 seconds for batch efficiency
    logLevel = "info";
    httpPort = ports.services.fluentbitMetrics;
    httpListen = "0.0.0.0";
    healthCheck = true;

    # Input settings
    inputPath = "/var/log/containers/loggen-*.log";
    inputTag = "kube.loggen.*";
    inputParser = "docker";
    refreshInterval = 5;
    rotateWait = 30;
    memBufLimit = "10MB";
    dbPath = "/var/lib/fluent-bit/tail.db";

    # Output settings
    outputHost = "clickhouse.otel-demo.svc.cluster.local";
    outputPort = ports.services.clickhouseHttp;
    outputUri = "/?query=INSERT%20INTO%20otel_logs%20FORMAT%20JSONEachRow&async_insert=1";
    outputRetryLimit = 5;
    outputWorkers = 2;
    outputCompress = "gzip";
  };

  # Build configuration files from config
  mkConfigDir = config: runCommand "fluentbit-config" { } ''
        mkdir -p $out/etc/fluent-bit/lua

        # Main configuration
        cat > $out/etc/fluent-bit/fluent-bit.conf << 'MAINCONF'
    [SERVICE]
        Flush        ${toString config.flushInterval}
        Log_Level    ${config.logLevel}
        Daemon       Off
        HTTP_Server  On
        HTTP_Listen  ${config.httpListen}
        HTTP_Port    ${toString config.httpPort}
        Health_Check ${if config.healthCheck then "On" else "Off"}
        HC_Errors_Count 5
        HC_Retry_Failure_Count 5
        HC_Period    5
        Parsers_File /etc/fluent-bit/parsers.conf

    @INCLUDE /etc/fluent-bit/inputs.conf
    @INCLUDE /etc/fluent-bit/filters.conf
    @INCLUDE /etc/fluent-bit/outputs.conf
    MAINCONF

        # Inputs configuration
        cat > $out/etc/fluent-bit/inputs.conf << 'INPUTCONF'
    [INPUT]
        Name              tail
        Tag               ${config.inputTag}
        Path              ${config.inputPath}
        Parser            ${config.inputParser}
        Refresh_Interval  ${toString config.refreshInterval}
        Rotate_Wait       ${toString config.rotateWait}
        Mem_Buf_Limit     ${config.memBufLimit}
        Skip_Long_Lines   On
        DB                ${config.dbPath}
        DB.Sync           Normal
    INPUTCONF

        # Filters configuration
        cat > $out/etc/fluent-bit/filters.conf << 'FILTERCONF'
    [FILTER]
        Name          parser
        Match         ${config.inputTag}
        Key_Name      log
        Parser        json
        Reserve_Data  On

    [FILTER]
        Name          kubernetes
        Match         ${config.inputTag}
        Merge_Log     On
        Keep_Log      Off
        K8S-Logging.Parser    On
        K8S-Logging.Exclude   On
        Kube_Tag_Prefix       kube.loggen.var.log.containers.

    [FILTER]
        Name          lua
        Match         ${config.inputTag}
        script        /etc/fluent-bit/lua/transform.lua
        call          transform_to_otel
    FILTERCONF

        # Outputs configuration
        cat > $out/etc/fluent-bit/outputs.conf << 'OUTPUTCONF'
    [OUTPUT]
        Name          http
        Match         *
        Host          ${config.outputHost}
        Port          ${toString config.outputPort}
        URI           ${config.outputUri}
        Format        json_lines
        Json_Date_Key false
        Retry_Limit   ${toString config.outputRetryLimit}
        Workers       ${toString config.outputWorkers}
        Header        Content-Type application/json
        compress      ${config.outputCompress}
    OUTPUTCONF

        # Parsers configuration
        cat > $out/etc/fluent-bit/parsers.conf << 'PARSERSCONF'
    [PARSER]
        Name        docker
        Format      json
        Time_Key    time
        Time_Format %Y-%m-%dT%H:%M:%S.%L
        Time_Keep   On

    [PARSER]
        Name        json
        Format      json
        Time_Key    ts
        Time_Format %s.%L
    PARSERSCONF

        # Lua transformation script
        cp ${./lua/transform.lua} $out/etc/fluent-bit/lua/transform.lua
  '';

  # Create a configured FluentBit derivation
  mkFluentbit = configOverrides:
    let
      config = defaultConfig // configOverrides;
      configDir = mkConfigDir config;
    in
    pkgs.symlinkJoin {
      name = "fluent-bit-configured";
      paths = [ fluentbitBase configDir ];

      meta = fluentbitBase.meta // {
        description = "FluentBit with OTel transformation configuration";
      };
    };

in
{
  # Default package for container use (backward compatible)
  package = mkFluentbit { };

  # Allow creating custom configurations
  inherit mkFluentbit defaultConfig;

  # Re-export for convenience
  inherit (ports.services) fluentbitMetrics clickhouseHttp;
}
