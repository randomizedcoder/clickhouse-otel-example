{ lib
, pkgs
, dockerTools
, buildEnv
, writeShellScript
, runCommand
, goApp
, fluentbit
, clickhouse
, hyperdx
}:

let
  # Import port configuration
  ports = import ./ports.nix;

  # Import container factory
  containerLib = import ./lib/containers.nix { inherit lib pkgs; };

  # ============================================
  # Standard Image Configurations
  # ============================================
  imageConfigs = {
    loggen = {
      packages = [ goApp ];
      pathsToLink = [ "/bin" ];
      entrypoint = [ "/bin/loggen" ];
      env = [
        "LOGGEN_MAX_NUMBER=100"
        "LOGGEN_NUM_STRINGS=10"
        "LOGGEN_SLEEP_DURATION=5s"
        "LOGGEN_HEALTH_PORT=${toString ports.services.loggenHealth}"
      ];
      exposedPorts = [ ports.services.loggenHealth ];
      description = "Log generator for OTel pipeline demo";
      includeTls = false;
      includeTz = false;
    };

    fluentbit = {
      packages = [ fluentbit ];
      pathsToLink = [ "/bin" "/etc" "/share" ];
      extraDirs = [ "var/lib/fluent-bit" "var/log" "tmp" ];
      entrypoint = [ "/bin/fluent-bit" ];
      cmd = [ "-c" "/etc/fluent-bit/fluent-bit.conf" ];
      exposedPorts = [ ports.services.fluentbitMetrics ];
      description = "FluentBit with OTel transformation";
    };

    mongodb = {
      packages = [ pkgs.mongodb pkgs.mongosh ];
      pathsToLink = [ "/bin" "/etc" "/share" ];
      extraDirs = [ "data/db" "var/log/mongodb" "tmp" ];
      entrypoint = [ "/bin/mongod" ];
      cmd = [ "--bind_ip_all" ];
      env = [ ];
      exposedPorts = [ ports.services.mongodb ];
      volumes = [ "/data/db" ];
      description = "MongoDB for HyperDX session storage";
      includeTls = false;
    };

    ferretdb = {
      packages = [ pkgs.ferretdb ];
      pathsToLink = [ "/bin" "/etc" "/share" ];
      extraDirs = [ "data" ];
      entrypoint = [ "/bin/ferretdb" ];
      cmd = [ "--handler=sqlite" "--sqlite-url=file:/data/" "--listen-addr=:27017" ];
      env = [ ];
      exposedPorts = [ ports.services.mongodb ];
      volumes = [ "/data" ];
      description = "FerretDB (MongoDB-compatible) with SQLite backend";
      includeTls = false;
    };

    hyperdx = {
      packages = [ hyperdx pkgs.nodejs_22 ];
      pathsToLink = [ "/bin" "/app" "/etc" "/share" ];
      extraDirs = [ "tmp" "app" ];
      entrypoint = [ "${hyperdx}/bin/hyperdx-start" ];
      workingDir = "/app";
      env = [
        "NODE_ENV=production"
        "HYPERDX_API_PORT=${toString ports.services.hyperdxApi}"
        "HYPERDX_APP_PORT=${toString ports.services.hyperdxApp}"
        "CLICKHOUSE_HOST=clickhouse"
        "CLICKHOUSE_PORT=${toString ports.services.clickhouseHttp}"
        # Enable local app mode (no auth required)
        "IS_LOCAL_APP_MODE=DANGEROUSLY_is_local_app_mode💀"
      ];
      exposedPorts = [ ports.services.hyperdxApi ports.services.hyperdxApp ];
      description = "HyperDX observability platform";
      includeShell = true;
    };

    # ClickHouse uses nix/clickhouse.nix module for configuration
    # includeShell is needed for K8s init script that creates tables on startup
    clickhouse = {
      packages = [ clickhouse ];
      pathsToLink = [ "/bin" "/etc" "/share" "/opt" ];
      extraDirs = [ "var/lib/clickhouse/tmp" "var/lib/clickhouse/user_files" "var/log/clickhouse-server" ];
      entrypoint = [ "/bin/clickhouse-server" ];
      cmd = [ "--config-file=/opt/clickhouse-config/config.xml" ];
      env = [ "CLICKHOUSE_DB=default" ];
      exposedPorts = [ ports.services.clickhouseHttp ports.services.clickhouseNative ports.services.clickhouseInterserver ];
      volumes = [ "/var/lib/clickhouse" ];
      description = "ClickHouse for OTel logs storage";
      includeShell = true;
    };
  };

  # Generate standard images using the factory
  standardImages = lib.mapAttrs
    (name: cfg:
      containerLib.mkImage (cfg // { inherit name; })
    )
    imageConfigs;

  # ============================================
  # All Images Combined
  # ============================================
  allImagesList = [
    { name = "loggen"; image = standardImages.loggen; }
    { name = "fluentbit"; image = standardImages.fluentbit; }
    { name = "clickhouse"; image = standardImages.clickhouse; }
    { name = "mongodb"; image = standardImages.mongodb; }
    { name = "ferretdb"; image = standardImages.ferretdb; }
    { name = "hyperdx"; image = standardImages.hyperdx; }
  ];

  # ============================================
  # Helper Scripts
  # ============================================
  loadScript = writeShellScript "load-images" ''
    set -e
    echo "Loading container images into Docker..."
    ${lib.concatMapStringsSep "\n" (img: ''
      echo "Loading ${img.name}..."
      ${pkgs.docker}/bin/docker load < ${img.image}
    '') allImagesList}
    echo ""
    echo "Images loaded successfully:"
    ${pkgs.docker}/bin/docker images | grep -E "(loggen|fluentbit|clickhouse|mongodb|ferretdb|hyperdx)" || true
  '';

  # Bundle all images
  allImages = runCommand "all-images" { } ''
    mkdir -p $out
    ${lib.concatMapStringsSep "\n" (img: ''
      cp ${img.image} $out/${img.name}.tar.gz
    '') allImagesList}
  '';

in
{
  loggenImage = standardImages.loggen;
  fluentbitImage = standardImages.fluentbit;
  clickhouseImage = standardImages.clickhouse;
  mongodbImage = standardImages.mongodb;
  ferretdbImage = standardImages.ferretdb;
  hyperdxImage = standardImages.hyperdx;
  inherit loadScript allImages;
}
