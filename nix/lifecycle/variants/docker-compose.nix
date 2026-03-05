# nix/lifecycle/variants/docker-compose.nix
#
# Full lifecycle test for Docker Compose deployment.
# Uses the unified transport abstraction and inline check code.
#
# Phases:
#   0: Build      - Validate compose file
#   1: Start      - docker compose up
#   2: Database   - Wait for ClickHouse, verify init tables
#   3: Setup      - Run compose-setup, verify GDP tables
#   4: Application - Verify logs flowing, all pipelines working
#   5: Shutdown   - docker compose down (graceful)
#   6: Exit       - Verify all containers stopped (force if needed)
#
{ pkgs, lib }:
let
  lifecycleLib = import ../lib.nix { inherit pkgs lib; };
  constants = import ../constants.nix { };
  transports = import ../transports.nix { inherit pkgs lib; };
  checkFactory = import ../checks/factory.nix { inherit pkgs lib; };

  ports = import ../../ports.nix;
  timeouts = constants.timeouts.docker-compose;
  variant = constants.variants.docker-compose;
in
{
  # Full lifecycle test
  test = pkgs.writeShellApplication {
    name = "lifecycle-test-docker-compose";
    runtimeInputs = lifecycleLib.commonInputs ++ lifecycleLib.dockerInputs;
    text = ''
      # Lifecycle Test: Docker Compose
      # ${variant.description}

      ${lifecycleLib.allHelpers}
      ${lifecycleLib.dockerHelpers}
      ${transports.mkTransport { variant = "docker-compose"; }}
      ${checkFactory.utilityFunctions}

      # Cleanup function
      cleanup() {
        local exit_code=$?
        if [[ "''${KEEP_ON_FAILURE:-}" == "1" ]] && [[ $exit_code -ne 0 ]]; then
          warn "Keeping deployment running for inspection (KEEP_ON_FAILURE=1)"
          warn "Run 'nix run .#compose-down' to stop"
          return
        fi
        info "Cleaning up..."
        nix run .#compose-down 2>/dev/null || true
      }
      trap cleanup EXIT

      bold "═══════════════════════════════════════════════════════════════"
      bold " Lifecycle Test: Docker Compose"
      bold " ${variant.description}"
      bold "═══════════════════════════════════════════════════════════════"
      echo ""

      # ─── Phase 0: Build ──────────────────────────────────────────────────
      run_phase "0" "Build" "${toString timeouts.build}"
      step "Validating compose file..."
      ${checkFactory.checkNixCommand { phase = "0"; name = "Compose valid"; command = "nix eval .#docker-compose-file --raw >/dev/null"; }}

      # ─── Phase 1: Start ──────────────────────────────────────────────────
      run_phase "1" "Start" "${toString timeouts.start}"
      step "Starting Docker Compose stack..."
      ${checkFactory.checkNixCommand { phase = "1"; name = "Compose up"; command = "nix run .#compose-up"; }}

      # ─── Phase 2: Database Ready ─────────────────────────────────────────
      run_phase "2" "Database Ready" "${toString timeouts.servicesReady}"

      # Wait for ClickHouse to respond
      ${checkFactory.waitForClickhouse { phase = "2"; timeout = 120; }}

      # Check init tables created by ClickHouse startup
      step "Checking init tables..."
      ${checkFactory.checkTableExists { phase = "2"; database = "default"; table = "otel_logs"; }}

      # ─── Phase 3: Setup & GDP Tables ─────────────────────────────────────
      run_phase "3" "Setup" "${toString timeouts.servicesReady}"

      step "Running compose-setup (creates GDP tables)..."
      ${checkFactory.checkNixCommand { phase = "3"; name = "compose-setup"; command = "nix run .#compose-setup"; }}

      # Wait for GDP tables to be created
      step "Verifying GDP tables..."
      ${checkFactory.waitForTable { phase = "3"; database = "gdp"; table = "ProtobufSingle"; timeout = 30; }}
      ${checkFactory.checkTableExists { phase = "3"; database = "gdp"; table = "ProtobufSingle_kafka"; }}
      ${checkFactory.checkTableExists { phase = "3"; database = "gdp"; table = "ProtobufSingle_mv"; }}

      # Check Kafka consumers are healthy
      step "Checking Kafka consumers..."
      sleep 5  # Give Kafka consumer time to connect
      ${checkFactory.checkKafkaConsumersHealthy { phase = "3"; }}

      # Verify HyperDX is ready
      step "Checking HyperDX..."
      ${checkFactory.checkHyperdxReady { phase = "3"; }}

      # Verify all containers are running
      step "Verifying containers..."
      ${lib.concatMapStringsSep "\n" (svc:
        checkFactory.checkContainerRunning { phase = "3"; name = svc; containerName = svc; }
      ) variant.services}

      # ─── Phase 4: Application Ready ──────────────────────────────────────
      run_phase "4" "Application Ready" "${toString timeouts.applicationReady}"

      step "Waiting for logs to flow..."
      sleep 30

      step "Checking log count..."
      ${checkFactory.checkLogCount { phase = "4"; threshold = 0; }}

      step "Verifying FluentBit pipeline..."
      ${checkFactory.checkFluentbitLogs { phase = "4"; threshold = 0; }}

      # Wait for GDP metrics (Kafka consumer needs time)
      step "Waiting for GDP metrics..."
      sleep 30

      step "Checking GDP metrics..."
      ${checkFactory.checkGdpMetricCount { phase = "4"; threshold = 0; }}

      # Final health checks
      step "Final health checks..."
      ${checkFactory.checkClickhouseReady { phase = "4"; }}
      ${checkFactory.checkHyperdxReady { phase = "4"; }}
      ${checkFactory.checkKafkaHealthy { phase = "4"; }}

      # ─── Phase 5: Shutdown ───────────────────────────────────────────────
      run_phase "5" "Shutdown" "${toString timeouts.shutdown}"
      step "Stopping Docker Compose (graceful)..."
      trap - EXIT  # Remove cleanup trap, we're doing it manually
      ${checkFactory.checkNixCommand { phase = "5"; name = "Compose down"; command = "nix run .#compose-down"; }}

      # ─── Phase 6: Wait Exit ──────────────────────────────────────────────
      run_phase "6" "Wait Exit" "${toString timeouts.waitExit}"
      step "Verifying containers stopped..."

      _exit_start=$(time_ms)
      _exit_timeout=${toString timeouts.waitExit}
      _exit_elapsed=0
      _poll_interval=2

      while [[ $_exit_elapsed -lt $_exit_timeout ]]; do
        # grep -c always outputs count, but exits non-zero when count is 0
        # Use || true to ignore grep's exit code, then default to 0 if empty
        running=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -c "^otel-" 2>/dev/null) || true
        running=''${running:-0}
        if [[ "$running" -eq 0 ]]; then
          _exit_ms=$(elapsed_ms "$_exit_start")
          result_pass "All containers stopped"
          record_result "6" "Containers stopped" "pass" "$_exit_ms"
          break
        fi
        debug "Still running: $running containers"
        sleep "$_poll_interval"
        _exit_elapsed=$((_exit_elapsed + _poll_interval))
      done

      if [[ $_exit_elapsed -ge $_exit_timeout ]]; then
        _exit_ms=$(elapsed_ms "$_exit_start")
        result_fail "Containers still running after timeout, forcing..."
        record_result "6" "Containers stopped" "fail" "$_exit_ms"
        # Force stop remaining containers
        docker ps --format '{{.Names}}' 2>/dev/null | grep "^otel-" | xargs -r docker rm -f 2>/dev/null || true
      fi

      # ─── Summary ─────────────────────────────────────────────────────────
      print_summary "Docker Compose Lifecycle Test"
    '';
  };

  # Individual phase scripts for debugging
  phase-3-services = pkgs.writeShellApplication {
    name = "lifecycle-docker-compose-phase-3";
    runtimeInputs = lifecycleLib.commonInputs ++ lifecycleLib.dockerInputs;
    text = ''
      ${lifecycleLib.colorHelpers}
      ${lifecycleLib.timingHelpers}
      ${lifecycleLib.resultHelpers}
      ${lifecycleLib.dockerHelpers}
      ${transports.mkTransport { variant = "docker-compose"; }}

      bold "Phase 3: Services Ready"
      echo ""

      ${lib.concatMapStringsSep "\n" (svc: ''
        if transport_check_container_running "${svc}"; then
          result_pass "Container ${svc} running"
        else
          result_fail "Container ${svc} not running"
        fi
      '') variant.services}
    '';
  };

  phase-4-application = pkgs.writeShellApplication {
    name = "lifecycle-docker-compose-phase-4";
    runtimeInputs = lifecycleLib.commonInputs ++ lifecycleLib.dockerInputs;
    text = ''
      ${lifecycleLib.colorHelpers}
      ${lifecycleLib.timingHelpers}
      ${lifecycleLib.resultHelpers}
      ${transports.mkTransport { variant = "docker-compose"; }}
      ${checkFactory.utilityFunctions}

      bold "Phase 4: Application Ready"
      echo ""

      # Check ClickHouse
      _result=$(transport_clickhouse_query "SELECT 1" 2>/dev/null || echo "")
      if [[ "$_result" == "1" ]]; then
        result_pass "ClickHouse responding"
      else
        result_fail "ClickHouse not responding"
      fi

      # Check otel_logs table
      _result=$(transport_clickhouse_query "SELECT count() FROM system.tables WHERE database='default' AND name='otel_logs'" 2>/dev/null || echo "")
      if [[ "$_result" == "1" ]]; then
        result_pass "otel_logs table exists"
      else
        result_fail "otel_logs table not found"
      fi

      # Check log count
      log_count=$(get_log_count)
      if [[ "$log_count" -gt 0 ]]; then
        result_pass "Logs in ClickHouse: $log_count"
      else
        result_fail "No logs in ClickHouse"
      fi

      # Check FluentBit logs
      count=$(transport_clickhouse_query "SELECT count() FROM otel_logs WHERE Body LIKE '%FluentBit%' AND Timestamp > now() - INTERVAL 1 MINUTE" 2>/dev/null || echo "0")
      count=''${count:-0}
      if [[ "$count" -gt 0 ]]; then
        result_pass "FluentBit pipeline: $count logs/min"
      else
        result_fail "FluentBit pipeline: no recent logs"
      fi

      # Check GDP
      _result=$(transport_clickhouse_query "SELECT count() FROM system.tables WHERE database='gdp' AND name='ProtobufSingle'" 2>/dev/null || echo "")
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

      # Check Kafka consumers
      _result=$(transport_clickhouse_query "SELECT countIf(length(exceptions.text) > 0) FROM system.kafka_consumers" 2>/dev/null || echo "")
      if [[ "$_result" == "0" ]]; then
        result_pass "Kafka consumers healthy"
      else
        result_fail "Kafka consumers have exceptions"
      fi

      # Check HyperDX
      if transport_hyperdx_health; then
        result_pass "HyperDX healthy"
      else
        result_fail "HyperDX not healthy"
      fi
    '';
  };
}
