# nix/lifecycle/variants/minikube.nix
#
# Full lifecycle test for host Minikube deployment.
# Uses the unified transport abstraction and inline check code.
#
# Phases: Build → Start → Load Images → Services Ready → Application Ready → Shutdown → Exit
#
{ pkgs, lib }:
let
  lifecycleLib = import ../lib.nix { inherit pkgs lib; };
  constants = import ../constants.nix { };
  mainConstants = import ../../constants.nix { inherit pkgs; };
  transports = import ../transports.nix { inherit pkgs lib; };
  checkFactory = import ../checks/factory.nix { inherit pkgs lib; };

  timeouts = constants.timeouts.minikube;
  variant = constants.variants.minikube;
  namespace = variant.namespace;
  imageNames = mainConstants.minikube.imageNames;
in
{
  # Full lifecycle test
  test = pkgs.writeShellApplication {
    name = "lifecycle-test-minikube";
    runtimeInputs = lifecycleLib.commonInputs ++ lifecycleLib.kubeInputs ++ lifecycleLib.dockerInputs;
    text = ''
      # Lifecycle Test: Minikube
      # ${variant.description}

      ${lifecycleLib.allHelpers}
      ${lifecycleLib.kubeHelpers}
      ${transports.mkTransport { variant = "minikube"; }}
      ${checkFactory.utilityFunctions}

      # Trap for cleanup on exit
      cleanup() {
        if [[ "''${KEEP_ON_FAILURE:-}" != "1" ]] || [[ $TOTAL_FAILED -eq 0 ]]; then
          info "Cleaning up..."
          minikube delete 2>/dev/null || true
        else
          warn "Keeping deployment running for inspection (KEEP_ON_FAILURE=1)"
        fi
      }
      trap cleanup EXIT

      bold "═══════════════════════════════════════════════════════════════"
      bold " Lifecycle Test: Minikube"
      bold " Host Minikube cluster"
      bold "═══════════════════════════════════════════════════════════════"
      echo ""

      # ─── Phase 0: Build ──────────────────────────────────────────────────
      run_phase "0" "Build" "${toString timeouts.build}"
      step "Building container images..."

      build_failed=false
      for img in ${lib.concatStringsSep " " imageNames}; do
        step "Building $img-image..."
        if nix build ".#''${img}-image" -o "/tmp/''${img}-image" 2>&1; then
          debug "Built $img-image"
        else
          result_fail "Failed to build $img-image"
          build_failed=true
        fi
      done

      if [[ "$build_failed" == "false" ]]; then
        result_pass "All images built"
        record_result "0" "Build" "pass" "0"
      else
        result_fail "Some images failed to build"
        record_result "0" "Build" "fail" "0"
      fi

      # ─── Phase 1: Start ──────────────────────────────────────────────────
      run_phase "1" "Start" "${toString timeouts.start}"
      step "Cleaning up any existing Minikube..."
      minikube delete 2>/dev/null || true

      step "Starting Minikube cluster..."
      _check_start=$(time_ms)
      if minikube start --driver=docker --memory=8g --cpus=4; then
        _check_elapsed=$(elapsed_ms "$_check_start")
        result_pass "Start"
        record_result "1" "Start" "pass" "$_check_elapsed"
      else
        _check_elapsed=$(elapsed_ms "$_check_start")
        result_fail "Start"
        record_result "1" "Start" "fail" "$_check_elapsed"
      fi

      # ─── Phase 2: Load Images ────────────────────────────────────────────
      run_phase "2" "Load Images" "${toString timeouts.imageLoad}"
      step "Loading images into Minikube..."

      load_failed=false
      for img in ${lib.concatStringsSep " " imageNames}; do
        step "Loading $img..."
        if minikube image load "/tmp/''${img}-image" 2>&1; then
          debug "Loaded $img"
        else
          result_fail "Failed to load $img"
          load_failed=true
        fi
      done

      if [[ "$load_failed" == "false" ]]; then
        result_pass "All images loaded"
        record_result "2" "Load images" "pass" "0"
      else
        result_fail "Some images failed to load"
        record_result "2" "Load images" "fail" "0"
      fi

      # ─── Phase 3: Services Ready ─────────────────────────────────────────
      run_phase "3" "Services Ready" "${toString timeouts.servicesReady}"

      step "Creating namespace and deploying..."
      kubectl create namespace "${namespace}" 2>/dev/null || true
      kubectl apply -f k8s/ -R 2>/dev/null || true
      result_pass "Manifests applied"
      record_result "3" "Deploy" "pass" "0"

      # Wait for database pods first (clickhouse, mongodb, redpanda)
      ${lib.concatMapStringsSep "\n" (p: ''
        step "Waiting for ${p.name} pod..."
        ${checkFactory.waitForPod { phase = "3"; name = p.name; label = p.label; timeout = timeouts.servicesReady; }}
      '') (lib.take 3 variant.pods)}

      # Give databases time to fully initialize before applications try to connect
      step "Waiting for databases to initialize..."
      sleep 30

      # Wait for application pods (otel-collector, fluentbit, loggen, hyperdx, gdp)
      ${lib.concatMapStringsSep "\n" (p: ''
        step "Waiting for ${p.name} pod..."
        ${checkFactory.waitForPod { phase = "3"; name = p.name; label = p.label; timeout = timeouts.servicesReady; }}
      '') (lib.drop 3 variant.pods)}

      # ─── Phase 4: Application Ready ──────────────────────────────────────
      run_phase "4" "Application Ready" "${toString timeouts.applicationReady}"

      step "Waiting for OTel collector to stabilize..."
      sleep 30

      step "Checking ClickHouse..."
      ${checkFactory.checkClickhouseReady { phase = "4"; }}

      step "Waiting for logs..."
      sleep 45

      step "Checking log count..."
      ${checkFactory.checkLogCount { phase = "4"; threshold = 0; }}

      step "Verifying FluentBit pipeline..."
      ${checkFactory.checkFluentbitLogs { phase = "4"; threshold = 0; }}

      step "Verifying OTLP pipeline..."
      ${checkFactory.checkOtlpLogs { phase = "4"; threshold = 0; }}

      step "Verifying Filelog pipeline..."
      ${checkFactory.checkFilelogLogs { phase = "4"; threshold = 0; }}

      # Show latency comparison
      step "Latency comparison:"
      kubectl exec -n "${namespace}" clickhouse-0 -- clickhouse-client --query "
        SELECT
            multiIf(
                Body LIKE '%FluentBit%', 'fluentbit',
                Body LIKE '%OTLP direct%', 'otlp',
                Body LIKE '%filelog receiver%', 'filelog',
                'unknown'
            ) AS pipeline,
            count() as log_count,
            round(avg(dateDiff('millisecond', Timestamp, IngestionTimestamp)), 0) as avg_latency_ms
        FROM otel_logs
        WHERE Timestamp > now() - INTERVAL 5 MINUTE
        GROUP BY pipeline
        ORDER BY avg_latency_ms
        FORMAT PrettyCompact
      " 2>/dev/null || echo "(latency query failed)"

      # Verify GDP pipeline
      step "Waiting for GDP metrics..."
      sleep 60

      step "Checking GDP table..."
      ${checkFactory.checkGdpTableExists { phase = "4"; }}

      step "Checking GDP metrics..."
      ${checkFactory.checkGdpMetricCount { phase = "4"; threshold = 0; }}

      step "Checking Kafka consumer..."
      ${checkFactory.checkKafkaHealthy { phase = "4"; }}

      step "Checking HyperDX..."
      ${checkFactory.checkHyperdxReady { phase = "4"; }}

      # ─── Phase 5: Shutdown ───────────────────────────────────────────────
      run_phase "5" "Shutdown" "${toString timeouts.shutdown}"
      step "Deleting Minikube cluster..."
      _check_start=$(time_ms)
      if minikube delete; then
        _check_elapsed=$(elapsed_ms "$_check_start")
        result_pass "Shutdown"
        record_result "5" "Shutdown" "pass" "$_check_elapsed"
      else
        _check_elapsed=$(elapsed_ms "$_check_start")
        result_fail "Shutdown"
        record_result "5" "Shutdown" "fail" "$_check_elapsed"
      fi

      # ─── Phase 6: Wait Exit ──────────────────────────────────────────────
      run_phase "6" "Wait Exit" "${toString timeouts.waitExit}"
      step "Verifying cluster gone..."
      sleep 2

      if ! minikube status 2>/dev/null | grep -q "Running"; then
        result_pass "Cluster stopped"
        record_result "6" "Exit" "pass" "0"
      else
        result_fail "Cluster still running"
        record_result "6" "Exit" "fail" "0"
      fi

      # ─── Summary ─────────────────────────────────────────────────────────
      trap - EXIT
      print_summary "Minikube Lifecycle Test"
    '';
  };

  # Individual phase scripts for debugging
  phase-3-services = pkgs.writeShellApplication {
    name = "lifecycle-minikube-phase-3";
    runtimeInputs = lifecycleLib.commonInputs ++ lifecycleLib.kubeInputs;
    text = ''
      ${lifecycleLib.colorHelpers}
      ${lifecycleLib.kubeHelpers}
      ${transports.mkTransport { variant = "minikube"; }}

      bold "Phase 3: Services Ready"
      echo ""

      ${lib.concatMapStringsSep "\n" (p: ''
        if transport_check_pod_ready "${p.label}"; then
          result_pass "Pod ${p.name} running"
        else
          result_fail "Pod ${p.name} not running"
        fi
      '') variant.pods}
    '';
  };

  phase-4-application = pkgs.writeShellApplication {
    name = "lifecycle-minikube-phase-4";
    runtimeInputs = lifecycleLib.commonInputs ++ lifecycleLib.kubeInputs;
    text = ''
      ${lifecycleLib.colorHelpers}
      ${lifecycleLib.timingHelpers}
      ${lifecycleLib.resultHelpers}
      ${transports.mkTransport { variant = "minikube"; }}
      ${checkFactory.utilityFunctions}

      bold "Phase 4: Application Ready"
      echo ""

      # Check ClickHouse
      _result=$(transport_clickhouse_query "SELECT 1" 2>/dev/null)
      if [[ "$_result" == "1" ]]; then
        result_pass "ClickHouse responding"
      else
        result_fail "ClickHouse not responding"
      fi

      # Check log count
      log_count=$(get_log_count)
      if [[ "$log_count" -gt 0 ]]; then
        result_pass "Logs in ClickHouse: $log_count"
      else
        result_fail "No logs in ClickHouse"
      fi

      # Check pipelines
      fluentbit_count=$(transport_clickhouse_query "SELECT count() FROM otel_logs WHERE Body LIKE '%FluentBit%' AND Timestamp > now() - INTERVAL 1 MINUTE" 2>/dev/null)
      fluentbit_count=''${fluentbit_count:-0}
      if [[ "$fluentbit_count" -gt 0 ]]; then
        result_pass "FluentBit: $fluentbit_count logs/min"
      else
        result_fail "FluentBit: no recent logs"
      fi

      otlp_count=$(transport_clickhouse_query "SELECT count() FROM otel_logs WHERE Body LIKE '%OTLP direct%' AND Timestamp > now() - INTERVAL 1 MINUTE" 2>/dev/null)
      otlp_count=''${otlp_count:-0}
      if [[ "$otlp_count" -gt 0 ]]; then
        result_pass "OTLP: $otlp_count logs/min"
      else
        result_fail "OTLP: no recent logs"
      fi

      filelog_count=$(transport_clickhouse_query "SELECT count() FROM otel_logs WHERE Body LIKE '%filelog receiver%' AND Timestamp > now() - INTERVAL 1 MINUTE" 2>/dev/null)
      filelog_count=''${filelog_count:-0}
      if [[ "$filelog_count" -gt 0 ]]; then
        result_pass "Filelog: $filelog_count logs/min"
      else
        result_fail "Filelog: no recent logs"
      fi

      # Check GDP
      _result=$(transport_clickhouse_query "SELECT count() FROM system.tables WHERE database='gdp' AND name='ProtobufSingle'" 2>/dev/null)
      if [[ "$_result" == "1" ]]; then
        result_pass "GDP table exists"
        gdp_count=$(get_gdp_count)
        if [[ "$gdp_count" -gt 0 ]]; then
          result_pass "GDP metrics: $gdp_count"
        else
          result_fail "No GDP metrics"
        fi
      else
        result_fail "GDP table not found"
      fi

      # Check HyperDX
      if transport_hyperdx_health; then
        result_pass "HyperDX ready"
      else
        result_fail "HyperDX not ready"
      fi
    '';
  };
}
