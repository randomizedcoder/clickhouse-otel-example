# nix/lifecycle/phases.nix
#
# Phase orchestration DSL for lifecycle tests.
# Provides a declarative way to define test phases and their checks.
#
# Each phase defines:
# - Name and description
# - Timeout
# - List of checks to run
# - Optional setup/teardown
#
{ pkgs, lib }:
let
  constants = import ./constants.nix { };
in
rec {
  # ─── Phase Definitions ─────────────────────────────────────────────────────
  # Standard phases used across all variants.
  #
  phases = {
    build = {
      number = 0;
      name = "Build";
      description = "Build images or VM";
    };
    start = {
      number = 1;
      name = "Start";
      description = "Start deployment";
    };
    consoleReady = {
      number = 2;
      name = "Console Ready";
      description = "Console or SSH accessible";
    };
    servicesReady = {
      number = 3;
      name = "Services Ready";
      description = "All services/pods running";
    };
    applicationReady = {
      number = 4;
      name = "Application Ready";
      description = "ClickHouse tables exist, logs flowing";
    };
    shutdown = {
      number = 5;
      name = "Shutdown";
      description = "Stop deployment";
    };
    waitExit = {
      number = 6;
      name = "Wait Exit";
      description = "Wait for clean exit";
    };
  };

  # ─── Timed Check Helpers ───────────────────────────────────────────────────
  # Helper functions for running checks with timing and recording.
  #
  timedCheckHelpers = ''
    # Run a check with timing and record result
    # Usage: run_check <phase> <name> <check_command>
    run_check() {
      local phase="$1"
      local name="$2"
      shift 2
      local start_time elapsed

      start_time=$(time_ms)
      if "$@"; then
        elapsed=$(elapsed_ms "$start_time")
        result_pass "$name"
        record_result "$phase" "$name" "pass" "$elapsed"
        return 0
      else
        elapsed=$(elapsed_ms "$start_time")
        result_fail "$name"
        record_result "$phase" "$name" "fail" "$elapsed"
        return 1
      fi
    }

    # Run a check that returns a value (like count)
    # Usage: run_check_value <phase> <name> <value_name> <check_command>
    # Returns: the value from the check command
    run_check_value() {
      local phase="$1"
      local name="$2"
      local value_name="$3"
      shift 3
      local start_time elapsed value

      start_time=$(time_ms)
      value=$("$@")
      elapsed=$(elapsed_ms "$start_time")

      if [[ -n "$value" ]] && [[ "$value" != "0" ]]; then
        result_pass "$name: $value_name=$value"
        record_result "$phase" "$name" "pass" "$elapsed"
        echo "$value"
        return 0
      else
        result_fail "$name: no $value_name"
        record_result "$phase" "$name" "fail" "$elapsed"
        echo "0"
        return 1
      fi
    }

    # Run a check with expected value comparison
    # Usage: run_check_expect <phase> <name> <expected> <check_command>
    run_check_expect() {
      local phase="$1"
      local name="$2"
      local expected="$3"
      shift 3
      local start_time elapsed value

      start_time=$(time_ms)
      value=$("$@")
      elapsed=$(elapsed_ms "$start_time")

      if [[ "$value" == "$expected" ]]; then
        result_pass "$name"
        record_result "$phase" "$name" "pass" "$elapsed"
        return 0
      else
        result_fail "$name (got: $value, expected: $expected)"
        record_result "$phase" "$name" "fail" "$elapsed"
        return 1
      fi
    }

    # Run a check with threshold (value must be > threshold)
    # Usage: run_check_threshold <phase> <name> <threshold> <check_command>
    run_check_threshold() {
      local phase="$1"
      local name="$2"
      local threshold="$3"
      shift 3
      local start_time elapsed value

      start_time=$(time_ms)
      value=$("$@")
      value=''${value:-0}
      elapsed=$(elapsed_ms "$start_time")

      if [[ "$value" -gt "$threshold" ]]; then
        result_pass "$name: $value"
        record_result "$phase" "$name" "pass" "$elapsed"
        echo "$value"
        return 0
      else
        result_fail "$name: $value (need > $threshold)"
        record_result "$phase" "$name" "fail" "$elapsed"
        echo "$value"
        return 1
      fi
    }

    # Run phase header with timeout
    # Usage: run_phase <phase_num> <phase_name> <timeout>
    run_phase() {
      local phase_num="$1"
      local phase_name="$2"
      local timeout="$3"
      phase_header "$phase_num" "$phase_name" "$timeout"
    }
  '';

  # ─── Variant-Specific Phase Runners ────────────────────────────────────────
  # Generate phase execution code for specific variants.
  #

  # Docker Compose phases
  dockerComposePhases = { timeouts }: ''
    # ─── Phase 0: Build ──────────────────────────────────────────────────
    run_phase "0" "Build" "${toString timeouts.build}"
    step "Validating compose file..."
    run_check "0" "Compose valid" nix eval .#docker-compose-file --raw

    # ─── Phase 1: Start ──────────────────────────────────────────────────
    run_phase "1" "Start" "${toString timeouts.start}"
    step "Starting Docker Compose stack..."
    run_check "1" "Start" nix run .#compose-up

    # ─── Phase 3: Services Ready ─────────────────────────────────────────
    run_phase "3" "Services Ready" "${toString timeouts.servicesReady}"

    step "Waiting for ClickHouse..."
    run_check "3" "ClickHouse" check_clickhouse_ready

    step "Running setup..."
    run_check "3" "Setup" nix run .#compose-setup

    sleep 5  # Give Kafka consumer time to initialize

    step "Waiting for HyperDX..."
    run_check "3" "HyperDX" check_hyperdx_ready

    # ─── Phase 4: Application Ready ──────────────────────────────────────
    run_phase "4" "Application Ready" "${toString timeouts.applicationReady}"

    step "Checking otel_logs table..."
    run_check "4" "otel_logs table" check_otel_logs_table

    step "Waiting for logs to flow..."
    sleep 30

    step "Checking log count..."
    run_check_threshold "4" "Log count" 0 get_log_count

    step "Verifying FluentBit pipeline..."
    run_check_threshold "4" "FluentBit logs" 0 check_fluentbit_logs || true

    step "Verifying GDP pipeline..."
    sleep 30  # GDP polls every 10s, Kafka consumer needs time
    run_check "4" "GDP table" check_gdp_table_exists
    run_check_threshold "4" "GDP metrics" 0 get_gdp_count || true
  '';

  # Minikube phases
  minikubePhases = { timeouts, imageNames }: ''
    # ─── Phase 0: Build ──────────────────────────────────────────────────
    run_phase "0" "Build" "${toString timeouts.build}"
    step "Building container images..."

    build_failed=false
    for img in ${lib.concatStringsSep " " imageNames}; do
      step "Building $img-image..."
      if ! nix build ".#''${img}-image" -o "/tmp/''${img}-image" 2>&1; then
        result_fail "Failed to build $img-image"
        build_failed=true
      fi
    done
    if [[ "$build_failed" == "false" ]]; then
      run_check "0" "Build" true
    else
      record_result "0" "Build" "fail" "0"
    fi

    # ─── Phase 1: Start ──────────────────────────────────────────────────
    run_phase "1" "Start" "${toString timeouts.start}"
    step "Cleaning up any existing Minikube..."
    minikube delete 2>/dev/null || true

    step "Starting Minikube cluster..."
    run_check "1" "Start" minikube start --driver=docker --memory=8g --cpus=4

    # ─── Phase 2: Load Images ────────────────────────────────────────────
    run_phase "2" "Load Images" "${toString timeouts.imageLoad}"
    step "Loading images into Minikube..."

    for img in ${lib.concatStringsSep " " imageNames}; do
      step "Loading $img..."
      minikube image load "/tmp/''${img}-image" 2>&1 || true
    done
    run_check "2" "Load images" true

    # ─── Phase 3: Services Ready ─────────────────────────────────────────
    run_phase "3" "Services Ready" "${toString timeouts.servicesReady}"

    step "Deploying manifests..."
    kubectl create namespace "$NAMESPACE" 2>/dev/null || true
    kubectl apply -f k8s/ -R 2>/dev/null || true
    run_check "3" "Deploy" true

    # Wait for pods
    for pod in clickhouse mongodb redpanda otel-collector fluentbit loggen hyperdx gdp; do
      step "Waiting for $pod pod..."
      run_check "3" "$pod" wait_''${pod}_ready 120 || true
    done

    # ─── Phase 4: Application Ready ──────────────────────────────────────
    run_phase "4" "Application Ready" "${toString timeouts.applicationReady}"

    step "Waiting for OTel collector to stabilize..."
    sleep 30

    step "Checking ClickHouse..."
    run_check "4" "ClickHouse" check_clickhouse_ready

    step "Waiting for logs..."
    sleep 45

    step "Checking log count..."
    run_check_threshold "4" "Log count" 0 get_log_count

    step "Verifying pipelines..."
    run_check_threshold "4" "FluentBit" 0 check_fluentbit_logs || true
    run_check_threshold "4" "OTLP" 0 check_otlp_logs || true
    run_check_threshold "4" "Filelog" 0 check_filelog_logs || true

    step "Waiting for GDP metrics..."
    sleep 60

    run_check "4" "GDP table" check_gdp_table_exists
    run_check_threshold "4" "GDP metrics" 0 get_gdp_count || true
    run_check "4" "Kafka" check_kafka_healthy
    run_check "4" "HyperDX" check_hyperdx_ready
  '';

  # MicroVM phases
  microvmPhases = { timeouts }: ''
    # ─── Phase 0: Build ──────────────────────────────────────────────────
    run_phase "0" "Build" "${toString timeouts.build}"
    step "Building MicroVM..."
    run_check "0" "Build" nix build .#nixosConfigurations.microvm-minikube.config.microvm.declaredRunner --no-link

    # ─── Phase 1: Start ──────────────────────────────────────────────────
    run_phase "1" "Start" "${toString timeouts.start}"

    step "Cleaning up existing MicroVM..."
    pkill -9 -f "microvm@otel-demo" 2>/dev/null || true
    rm -f var.img control.sock 2>/dev/null || true
    sleep 2

    step "Starting MicroVM..."
    nix run .#microvm-minikube > "$VM_LOG" 2>&1 &
    VM_PID=$!
    sleep 3

    if kill -0 "$VM_PID" 2>/dev/null; then
      result_pass "MicroVM started (PID: $VM_PID)"
      record_result "1" "Start" "pass" "0"
    else
      result_fail "MicroVM failed to start"
      record_result "1" "Start" "fail" "0"
      print_summary "MicroVM Lifecycle Test"
      exit 1
    fi

    # ─── Phase 2: SSH Ready ──────────────────────────────────────────────
    run_phase "2" "SSH Ready" "${toString timeouts.sshReady}"
    step "Waiting for SSH..."

    SSH_READY=false
    if elapsed=$(wait_for_port "localhost" "$SSH_PORT" "${toString timeouts.sshReady}"); then
      sleep 2
      if transport_ssh_ready; then
        result_pass "SSH accessible"
        record_result "2" "SSH" "pass" "$elapsed"
        SSH_READY=true
      else
        result_fail "SSH port open but authentication failed"
        record_result "2" "SSH" "fail" "$elapsed"
      fi
    else
      result_fail "SSH not accessible"
      record_result "2" "SSH" "fail" "0"
    fi

    # ─── Phase 2b: Minikube Ready ────────────────────────────────────────
    if [[ "$SSH_READY" == "true" ]]; then
      run_phase "2b" "Minikube Ready" "${toString timeouts.minikubeReady}"
      step "Waiting for Minikube inside VM..."

      MINIKUBE_READY=false
      timeout_secs=${toString timeouts.minikubeReady}
      elapsed_secs=0
      poll_interval=5

      while [[ $elapsed_secs -lt $timeout_secs ]]; do
        if transport_minikube_running; then
          result_pass "Minikube running inside VM"
          record_result "2b" "Minikube" "pass" "$((elapsed_secs * 1000))"
          MINIKUBE_READY=true
          break
        fi
        sleep "$poll_interval"
        elapsed_secs=$((elapsed_secs + poll_interval))
      done

      if [[ "$MINIKUBE_READY" != "true" ]]; then
        result_fail "Minikube not ready inside VM"
        record_result "2b" "Minikube" "fail" "0"
      fi
    else
      result_skip "Minikube check (SSH not available)"
      record_result "2b" "Minikube" "skip" "0"
      MINIKUBE_READY=false
    fi

    # ─── Phase 3: Services Ready ─────────────────────────────────────────
    if [[ "$MINIKUBE_READY" == "true" ]]; then
      run_phase "3" "Services Ready" "${toString timeouts.servicesReady}"
      step "Waiting for pods inside VM..."

      # Check critical pods
      for pod in clickhouse hyperdx gdp; do
        run_check "3" "$pod" check_''${pod}_ready || true
      done
    else
      result_skip "Services check (Minikube not available)"
      record_result "3" "Services" "skip" "0"
    fi

    # ─── Phase 4: Application Ready ──────────────────────────────────────
    if [[ "$MINIKUBE_READY" == "true" ]]; then
      run_phase "4" "Application Ready" "${toString timeouts.applicationReady}"

      step "Waiting for logs..."
      sleep 60

      step "Checking ClickHouse..."
      run_check "4" "ClickHouse" check_clickhouse_ready

      step "Checking log count..."
      run_check_threshold "4" "Log count" 0 get_log_count

      step "Verifying pipelines..."
      run_check_threshold "4" "FluentBit" 0 check_fluentbit_logs || true
      run_check_threshold "4" "OTLP" 0 check_otlp_logs || true
      run_check_threshold "4" "Filelog" 0 check_filelog_logs || true

      step "Checking GDP..."
      run_check "4" "GDP table" check_gdp_table_exists
      run_check_threshold "4" "GDP metrics" 0 get_gdp_count || true
      run_check "4" "Kafka" check_kafka_healthy
      run_check "4" "HyperDX" check_hyperdx_ready
    else
      result_skip "Application check (pods not ready)"
      record_result "4" "Application" "skip" "0"
    fi
  '';

  # Shutdown phases (common)
  shutdownPhases = { variant, timeout }: ''
    # ─── Phase 5: Shutdown ───────────────────────────────────────────────
    run_phase "5" "Shutdown" "${toString timeout}"
    ${if variant == "docker-compose" then ''
      step "Stopping Docker Compose..."
      run_check "5" "Shutdown" nix run .#compose-down
    '' else if variant == "minikube" then ''
      step "Deleting Minikube cluster..."
      run_check "5" "Shutdown" minikube delete
    '' else ''
      step "Stopping MicroVM..."
      if [[ "$SSH_READY" == "true" ]]; then
        step "Sending poweroff via SSH..."
        _ssh_cmd "poweroff" 2>/dev/null || true
        sleep 5
      fi
      if [[ -n "$VM_PID" ]] && kill -0 "$VM_PID" 2>/dev/null; then
        step "Killing VM process..."
        kill "$VM_PID" 2>/dev/null || true
        sleep 2
        kill -9 "$VM_PID" 2>/dev/null || true
      fi
      result_pass "MicroVM stopped"
      record_result "5" "Shutdown" "pass" "0"
    ''}
  '';

  # Wait exit phases (common)
  waitExitPhases = { variant, timeout }: ''
    # ─── Phase 6: Wait Exit ──────────────────────────────────────────────
    run_phase "6" "Wait Exit" "${toString timeout}"
    step "Verifying clean exit..."
    sleep 2

    ${if variant == "docker-compose" then ''
      running=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -c "^otel-") || running=0
      if [[ "$running" -eq 0 ]]; then
        result_pass "All containers stopped"
        record_result "6" "Exit" "pass" "0"
      else
        result_fail "Some containers still running: $running"
        record_result "6" "Exit" "fail" "0"
      fi
    '' else if variant == "minikube" then ''
      if ! minikube status 2>/dev/null | grep -q "Running"; then
        result_pass "Cluster stopped"
        record_result "6" "Exit" "pass" "0"
      else
        result_fail "Cluster still running"
        record_result "6" "Exit" "fail" "0"
      fi
    '' else ''
      if ! process_running "microvm@otel-demo"; then
        result_pass "VM process exited"
        record_result "6" "Exit" "pass" "0"
      else
        result_fail "VM process still running"
        record_result "6" "Exit" "fail" "0"
        pkill -9 -f "microvm@otel-demo" 2>/dev/null || true
      fi
      rm -f var.img control.sock "$VM_LOG" 2>/dev/null || true
    ''}
  '';

  # Export everything
  inherit phases timedCheckHelpers;
  inherit dockerComposePhases minikubePhases microvmPhases;
  inherit shutdownPhases waitExitPhases;
}
