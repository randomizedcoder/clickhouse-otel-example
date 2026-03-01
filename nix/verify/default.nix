# Pipeline verification scripts - modular entry point
# Verify each stage of the logging pipeline and inject failures for testing
{ pkgs }:
let
  shellLib = import ../lib/shell.nix { inherit (pkgs) lib; inherit pkgs; };

  # Import all script modules
  positiveScripts = import ./positive.nix { inherit pkgs shellLib; };
  initScripts = import ./init.nix { inherit pkgs shellLib; };
  breakFixScripts = import ./break-fix.nix { inherit pkgs shellLib; };
  latencyScripts = import ./latency.nix { inherit pkgs shellLib; };
  testScripts = import ./test-harness.nix { inherit pkgs shellLib; };
  integrationScripts = import ./integration.nix { inherit pkgs shellLib; };

  # Merge all scripts
  allScripts =
    positiveScripts
    // initScripts
    // breakFixScripts
    // latencyScripts
    // testScripts
    // integrationScripts;

  # Script metadata for documentation and tooling
  scriptMetadata = {
    # Positive verification
    verify-loggen = {
      category = "verify";
      description = "Verify loggen pod is running and emitting JSON logs";
      component = "loggen";
    };
    verify-fluentbit = {
      category = "verify";
      description = "Verify FluentBit is processing logs without errors";
      component = "fluentbit";
    };
    verify-fluentbit-output = {
      category = "verify";
      description = "Verify FluentBit is sending logs to ClickHouse";
      component = "fluentbit";
    };
    verify-clickhouse = {
      category = "verify";
      description = "Verify ClickHouse is storing logs correctly";
      component = "clickhouse";
    };
    verify-hyperdx = {
      category = "verify";
      description = "Verify HyperDX UI is accessible";
      component = "hyperdx";
    };
    verify-pipeline = {
      category = "verify";
      description = "Run all verification scripts in sequence";
      component = "pipeline";
    };

    # Break scripts
    break-loggen = {
      category = "break";
      description = "Scale loggen to 0 replicas";
      component = "loggen";
      related = [ "fix-loggen" "verify-loggen" ];
    };
    break-fluentbit = {
      category = "break";
      description = "Break FluentBit with invalid image";
      component = "fluentbit";
      related = [ "fix-fluentbit" "verify-fluentbit" ];
    };
    break-fluentbit-lua = {
      category = "break";
      description = "Inject Lua syntax error in FluentBit";
      component = "fluentbit";
      related = [ "fix-fluentbit-lua" "verify-fluentbit" ];
    };
    break-fluentbit-output = {
      category = "break";
      description = "Point FluentBit to wrong host";
      component = "fluentbit";
      related = [ "fix-fluentbit-output" "verify-fluentbit-output" ];
    };
    break-clickhouse = {
      category = "break";
      description = "Scale ClickHouse to 0 replicas";
      component = "clickhouse";
      related = [ "fix-clickhouse" "verify-clickhouse" ];
    };
    break-clickhouse-table = {
      category = "break";
      description = "Drop the otel_logs table";
      component = "clickhouse";
      related = [ "fix-clickhouse-table" "verify-clickhouse" ];
    };
    break-hyperdx = {
      category = "break";
      description = "Scale HyperDX to 0 replicas";
      component = "hyperdx";
      related = [ "fix-hyperdx" "verify-hyperdx" ];
    };

    # Fix scripts
    fix-loggen = {
      category = "fix";
      description = "Restore loggen to 1 replica";
      component = "loggen";
    };
    fix-fluentbit = {
      category = "fix";
      description = "Rollback FluentBit daemonset";
      component = "fluentbit";
    };
    fix-fluentbit-lua = {
      category = "fix";
      description = "Restore FluentBit Lua config";
      component = "fluentbit";
    };
    fix-fluentbit-output = {
      category = "fix";
      description = "Restore FluentBit output config";
      component = "fluentbit";
    };
    fix-clickhouse = {
      category = "fix";
      description = "Restore ClickHouse to 1 replica";
      component = "clickhouse";
    };
    fix-clickhouse-table = {
      category = "fix";
      description = "Recreate the otel_logs table";
      component = "clickhouse";
    };
    fix-hyperdx = {
      category = "fix";
      description = "Restore HyperDX to 1 replica";
      component = "hyperdx";
    };

    # Latency measurement
    measure-latency = {
      category = "measure";
      description = "Analyze age of recent logs in ClickHouse";
      component = "pipeline";
    };
    measure-latency-active = {
      category = "measure";
      description = "Wait for new logs and measure end-to-end latency";
      component = "pipeline";
    };

    # Test harness
    test-verify-scripts = {
      category = "test";
      description = "Run full break/fix/verify test suite";
      component = "pipeline";
    };

    # Init scripts
    init-clickhouse = {
      category = "init";
      description = "Initialize ClickHouse with otel_logs table";
      component = "clickhouse";
    };

    # Integration test scripts
    test-docker-compose = {
      category = "integration";
      description = "Test Docker Compose deployment end-to-end";
      component = "deployment";
    };
    test-minikube = {
      category = "integration";
      description = "Test standalone Minikube deployment end-to-end";
      component = "deployment";
    };
    test-microvm = {
      category = "integration";
      description = "Test MicroVM with Minikube deployment end-to-end";
      component = "deployment";
    };
    test-all-deployments = {
      category = "integration";
      description = "Run all deployment integration tests sequentially";
      component = "deployment";
    };
  };

in
allScripts // {
  # Export metadata for tooling
  _scriptNames = builtins.attrNames allScripts;
  _metadata = scriptMetadata;
  _categories = {
    verify = builtins.filter (n: (scriptMetadata.${n}.category or "") == "verify") (builtins.attrNames scriptMetadata);
    break = builtins.filter (n: (scriptMetadata.${n}.category or "") == "break") (builtins.attrNames scriptMetadata);
    fix = builtins.filter (n: (scriptMetadata.${n}.category or "") == "fix") (builtins.attrNames scriptMetadata);
    measure = builtins.filter (n: (scriptMetadata.${n}.category or "") == "measure") (builtins.attrNames scriptMetadata);
    init = builtins.filter (n: (scriptMetadata.${n}.category or "") == "init") (builtins.attrNames scriptMetadata);
    test = builtins.filter (n: (scriptMetadata.${n}.category or "") == "test") (builtins.attrNames scriptMetadata);
    integration = builtins.filter (n: (scriptMetadata.${n}.category or "") == "integration") (builtins.attrNames scriptMetadata);
  };
}
