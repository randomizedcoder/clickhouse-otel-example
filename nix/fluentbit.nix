{ lib
, pkgs
, runCommand
, fluent-bit
}:

# Use the nixpkgs fluent-bit package and add our custom configuration
let
  # Base FluentBit from nixpkgs
  fluentbitBase = fluent-bit;

  # Our custom configuration files
  configDir = runCommand "fluentbit-config" { } ''
    mkdir -p $out/etc/fluent-bit/lua

    # Main configuration
    cat > $out/etc/fluent-bit/fluent-bit.conf << 'MAINCONF'
[SERVICE]
    Flush        1
    Log_Level    info
    Daemon       Off
    HTTP_Server  On
    HTTP_Listen  0.0.0.0
    HTTP_Port    2020
    Health_Check On
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
    Tag               kube.loggen.*
    Path              /var/log/containers/loggen-*.log
    Parser            docker
    Refresh_Interval  5
    Rotate_Wait       30
    Mem_Buf_Limit     10MB
    Skip_Long_Lines   On
    DB                /var/lib/fluent-bit/tail.db
    DB.Sync           Normal
INPUTCONF

    # Filters configuration
    cat > $out/etc/fluent-bit/filters.conf << 'FILTERCONF'
[FILTER]
    Name          parser
    Match         kube.loggen.*
    Key_Name      log
    Parser        json
    Reserve_Data  On

[FILTER]
    Name          lua
    Match         kube.loggen.*
    script        /etc/fluent-bit/lua/transform.lua
    call          transform_to_otel
FILTERCONF

    # Outputs configuration
    cat > $out/etc/fluent-bit/outputs.conf << 'OUTPUTCONF'
[OUTPUT]
    Name          http
    Match         *
    Host          clickhouse.otel-demo.svc.cluster.local
    Port          8123
    URI           /?query=INSERT%20INTO%20otel_logs%20FORMAT%20JSONEachRow
    Format        json_lines
    Json_Date_Key false
    Retry_Limit   5
    Workers       2
    Header        Content-Type application/json
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

in
pkgs.symlinkJoin {
  name = "fluent-bit-configured";
  paths = [ fluentbitBase configDir ];

  meta = fluentbitBase.meta // {
    description = "FluentBit with OTel transformation configuration";
  };
}
