# nix/lifecycle/variants/microvm.nix
#
# Full lifecycle test for MicroVM deployment.
# Uses the unified transport abstraction and inline check code.
#
# Phases: Build → Start → SSH Ready → Minikube Ready → Services Ready → Application Ready → Shutdown → Exit
#
{ pkgs, lib }:
let
  lifecycleLib = import ../lib.nix { inherit pkgs lib; };
  constants = import ../constants.nix { };
  transports = import ../transports.nix { inherit pkgs lib; };
  checkFactory = import ../checks/factory.nix { inherit pkgs lib; };

  ports = import ../../ports.nix;
  timeouts = constants.timeouts.microvm;
  variant = constants.variants.microvm;
  namespace = variant.namespace;

  sshPort = toString variant.sshPort;
  sshUser = variant.sshUser;
  sshPass = variant.sshPassword;
in
{
  # Full lifecycle test
  test = pkgs.writeShellApplication {
    name = "lifecycle-test-microvm";
    runtimeInputs = lifecycleLib.commonInputs ++ lifecycleLib.sshInputs ++ lifecycleLib.expectInputs;
    text = ''
      # Lifecycle Test: MicroVM
      # ${variant.description}

      ${lifecycleLib.allHelpers}
      ${lifecycleLib.sshHelpers}
      ${lifecycleLib.processHelpers}
      ${lifecycleLib.consoleHelpers}
      ${transports.mkTransport { variant = "microvm"; }}
      ${checkFactory.utilityFunctions}

      VM_LOG="/tmp/microvm-lifecycle-$$.log"
      VM_PID=""

      # Trap for cleanup on exit
      cleanup() {
        if [[ "''${KEEP_ON_FAILURE:-}" != "1" ]] || [[ $TOTAL_FAILED -eq 0 ]]; then
          info "Cleaning up..."
          if [[ -n "$VM_PID" ]] && kill -0 "$VM_PID" 2>/dev/null; then
            kill "$VM_PID" 2>/dev/null || true
          fi
          pkill -f "microvm@otel-demo" 2>/dev/null || true
          rm -f var.img control.sock "$VM_LOG" 2>/dev/null || true
        else
          warn "Keeping deployment running for inspection (KEEP_ON_FAILURE=1)"
          warn "VM log: $VM_LOG"
        fi
      }
      trap cleanup EXIT

      bold "═══════════════════════════════════════════════════════════════"
      bold " Lifecycle Test: MicroVM"
      bold " ${variant.description}"
      bold "═══════════════════════════════════════════════════════════════"
      echo ""

      # ─── Phase 0: Build ──────────────────────────────────────────────────
      run_phase "0" "Build" "${toString timeouts.build}"
      step "Building MicroVM..."
      _check_start=$(time_ms)
      if nix build .#nixosConfigurations.microvm-minikube.config.microvm.declaredRunner --no-link; then
        _check_elapsed=$(elapsed_ms "$_check_start")
        result_pass "Build"
        record_result "0" "Build" "pass" "$_check_elapsed"
      else
        _check_elapsed=$(elapsed_ms "$_check_start")
        result_fail "Build"
        record_result "0" "Build" "fail" "$_check_elapsed"
      fi

      # ─── Phase 1: Start ──────────────────────────────────────────────────
      run_phase "1" "Start" "${toString timeouts.start}"

      step "Cleaning up existing MicroVM..."
      pkill -9 -f "microvm@otel-demo" 2>/dev/null || true
      rm -f var.img control.sock 2>/dev/null || true
      sleep 2

      # Check port is free
      if nc -z localhost "${sshPort}" 2>/dev/null; then
        result_fail "Port ${sshPort} already in use"
        record_result "1" "Start" "fail" "0"
        print_summary "MicroVM Lifecycle Test"
        exit 1
      fi

      step "Starting MicroVM..."
      start_time=$(time_ms)

      nix run .#microvm-minikube > "$VM_LOG" 2>&1 &
      VM_PID=$!

      sleep 3

      if kill -0 "$VM_PID" 2>/dev/null; then
        elapsed=$(elapsed_ms "$start_time")
        result_pass "MicroVM started (PID: $VM_PID)"
        record_result "1" "Start" "pass" "$elapsed"
        info "  VM log: $VM_LOG"
      else
        elapsed=$(elapsed_ms "$start_time")
        result_fail "MicroVM failed to start"
        record_result "1" "Start" "fail" "$elapsed"
        if [[ -f "$VM_LOG" ]]; then
          warn "Last 20 lines of VM log:"
          tail -20 "$VM_LOG" 2>/dev/null || true
        fi
        print_summary "MicroVM Lifecycle Test"
        exit 1
      fi

      # ─── Phase 2a: Serial Console Ready ─────────────────────────────────────
      run_phase "2a" "Serial Console" "${toString timeouts.serialReady}"
      step "Waiting for serial console (ttyS0)..."
      start_time=$(time_ms)

      SERIAL_READY=false
      if elapsed=$(wait_for_port "localhost" "${toString ports.console.serial}" "${toString timeouts.serialReady}"); then
        result_pass "Serial console available (port ${toString ports.console.serial})"
        record_result "2a" "Serial" "pass" "$elapsed"
        SERIAL_READY=true
      else
        elapsed=$(elapsed_ms "$start_time")
        result_fail "Serial console not available (port ${toString ports.console.serial})"
        record_result "2a" "Serial" "fail" "$elapsed"
      fi

      # ─── Phase 2b: Virtio Console Ready ────────────────────────────────────
      # NOTE: Virtio console (hvc0) requires PCI, which the "microvm" machine type
      # doesn't have. Skip this phase and use serial console for debugging instead.
      result_skip "Virtio console (microvm machine has no PCI bus)"
      record_result "2b" "Virtio" "skip" "0"

      # ─── Phase 2c: SSH Ready ──────────────────────────────────────────────
      # NOTE: QEMU port forwarding is ready immediately, but the guest SSH daemon
      # needs time to start. We poll for actual SSH connectivity, not just port.
      run_phase "2c" "SSH Ready" "${toString timeouts.sshReady}"
      step "Waiting for SSH (polling for actual connectivity)..."
      start_time=$(time_ms)

      SSH_READY=false
      ssh_timeout=${toString timeouts.sshReady}
      ssh_elapsed=0
      poll_interval=${toString constants.polling.slowInterval}

      while [[ $ssh_elapsed -lt $ssh_timeout ]]; do
        if transport_ssh_ready; then
          elapsed=$(elapsed_ms "$start_time")
          result_pass "SSH accessible (after ''${ssh_elapsed}s)"
          record_result "2c" "SSH" "pass" "$elapsed"
          SSH_READY=true
          break
        fi
        sleep "$poll_interval"
        ssh_elapsed=$((ssh_elapsed + poll_interval))
      done

      if [[ "$SSH_READY" != "true" ]]; then
        elapsed=$(elapsed_ms "$start_time")
        result_fail "SSH not accessible after ${toString timeouts.sshReady}s"
        record_result "2c" "SSH" "fail" "$elapsed"
        if [[ -f "$VM_LOG" ]]; then
          warn "Last 20 lines of VM log:"
          tail -20 "$VM_LOG" 2>/dev/null || true
        fi
        # Dump serial console logs for debugging
        if [[ "$SERIAL_READY" == "true" ]]; then
          warn "Dumping serial console for debugging..."
          dump_console_log "${toString ports.console.serial}" 3 || true
        fi
      fi

      # ─── Phase 2d: Minikube Ready ────────────────────────────────────────
      if [[ "$SSH_READY" == "true" ]]; then
        run_phase "2d" "Minikube Ready" "${toString timeouts.minikubeReady}"
        step "Waiting for Minikube inside VM..."
        start_time=$(time_ms)

        MINIKUBE_READY=false
        timeout_secs=${toString timeouts.minikubeReady}
        elapsed_secs=0
        poll_interval=${toString constants.polling.slowInterval}

        while [[ $elapsed_secs -lt $timeout_secs ]]; do
          if transport_minikube_running; then
            elapsed=$(elapsed_ms "$start_time")
            result_pass "Minikube running inside VM"
            record_result "2d" "Minikube" "pass" "$elapsed"
            MINIKUBE_READY=true
            break
          fi
          sleep "$poll_interval"
          elapsed_secs=$((elapsed_secs + poll_interval))
        done

        if [[ "$MINIKUBE_READY" != "true" ]]; then
          elapsed=$(elapsed_ms "$start_time")
          result_fail "Minikube not ready inside VM"
          record_result "2d" "Minikube" "fail" "$elapsed"
        fi
      else
        result_skip "Minikube check (SSH not available)"
        record_result "2d" "Minikube" "skip" "0"
        MINIKUBE_READY=false
      fi

      # ─── Phase 3: Services Ready ─────────────────────────────────────────
      if [[ "$MINIKUBE_READY" == "true" ]]; then
        run_phase "3" "Services Ready" "${toString timeouts.servicesReady}"
        step "Waiting for pods inside VM..."
        start_time=$(time_ms)

        PODS_READY=false
        timeout_secs=${toString timeouts.servicesReady}
        elapsed_secs=0
        poll_interval=${toString constants.polling.slowInterval}

        while [[ $elapsed_secs -lt $timeout_secs ]]; do
          pod_count=$(_ssh_cmd "kubectl get pods -n ${namespace} --no-headers 2>/dev/null | grep -c Running || echo 0" 2>/dev/null | tail -1 | tr -d '[:space:]')
          pod_count=''${pod_count:-0}

          if [[ "$pod_count" -ge 4 ]]; then
            elapsed=$(elapsed_ms "$start_time")
            result_pass "Pods running: $pod_count"
            record_result "3" "Pods" "pass" "$elapsed"
            PODS_READY=true
            break
          fi

          debug "Pod count: $pod_count"
          sleep "$poll_interval"
          elapsed_secs=$((elapsed_secs + poll_interval))
        done

        if [[ "$PODS_READY" != "true" ]]; then
          elapsed=$(elapsed_ms "$start_time")
          result_fail "Not enough pods running: $pod_count"
          record_result "3" "Pods" "fail" "$elapsed"
        fi

        # Check individual critical pods with container status diagnostics
        for pod_info in "app=clickhouse|clickhouse" "app=hyperdx|hyperdx" "app=gdp|gdp"; do
          IFS='|' read -r label name <<< "$pod_info"
          start_time=$(time_ms)
          if _ssh_cmd "kubectl wait --for=condition=ready pod -l $label -n ${namespace} --timeout=30s" 2>/dev/null; then
            elapsed=$(elapsed_ms "$start_time")
            result_pass "$name pod ready"
            record_result "3" "$name" "pass" "$elapsed"
          else
            elapsed=$(elapsed_ms "$start_time")
            # Get detailed pod status to distinguish "starting" vs "failing"
            pod_status=$(_ssh_cmd "kubectl get pods -l $label -n ${namespace} -o jsonpath='{.items[0].status.phase}'" 2>/dev/null | tr -d "'" || echo "Unknown")
            container_status=$(_ssh_cmd "kubectl get pods -l $label -n ${namespace} -o jsonpath='{.items[0].status.containerStatuses[0].state}'" 2>/dev/null | tr -d "'" || echo "")

            # Check for known "still starting" states
            if [[ "$pod_status" == "Pending" ]] || [[ "$container_status" == *"waiting"*"ContainerCreating"* ]]; then
              result_warn "$name pod starting (status: $pod_status)"
              record_result "3" "$name" "warn" "$elapsed"
            elif [[ "$container_status" == *"waiting"*"CrashLoopBackOff"* ]] || [[ "$container_status" == *"waiting"*"ImagePullBackOff"* ]] || [[ "$container_status" == *"waiting"*"ErrImagePull"* ]]; then
              # These are actual failures
              result_fail "$name pod failing: $container_status"
              record_result "3" "$name" "fail" "$elapsed"
              # Show pod events for debugging
              warn "Recent events for $name:"
              _ssh_cmd "kubectl get events -n ${namespace} --field-selector involvedObject.name=\$(_ssh_cmd \"kubectl get pods -l $label -n ${namespace} -o jsonpath='{.items[0].metadata.name}'\" 2>/dev/null | tr -d \"'\") --sort-by='.lastTimestamp' 2>/dev/null | tail -5" 2>/dev/null || true
            elif [[ "$pod_status" == "Running" ]]; then
              # Running but not ready - try actual connectivity test via kubectl exec
              restart_count=$(_ssh_cmd "kubectl get pods -l $label -n ${namespace} -o jsonpath='{.items[0].status.containerStatuses[0].restartCount}'" 2>/dev/null | tr -d "'" || echo "0")
              pod_name=$(_ssh_cmd "kubectl get pods -l $label -n ${namespace} -o jsonpath='{.items[0].metadata.name}'" 2>/dev/null | tr -d "'" || echo "")

              # For specific services, check actual connectivity via kubectl exec (not cluster DNS)
              if [[ "$name" == "clickhouse" ]] && [[ -n "$pod_name" ]]; then
                # Test ClickHouse query via exec into pod
                ch_test=$(_ssh_cmd "kubectl exec -n ${namespace} $pod_name -- clickhouse-client -q 'SELECT 1'" 2>/dev/null | tr -d '[:space:]' || echo "")
                if [[ "$ch_test" == "1" ]]; then
                  result_pass "$name pod ready (SELECT 1 works)"
                  record_result "3" "$name" "pass" "$elapsed"
                else
                  result_warn "$name pod running, query failed (restarts: $restart_count)"
                  record_result "3" "$name" "warn" "$elapsed"
                fi
              elif [[ "$name" == "hyperdx" ]] && [[ -n "$pod_name" ]]; then
                # Test HyperDX health via exec (curl localhost inside container)
                hdx_test=$(_ssh_cmd "kubectl exec -n ${namespace} $pod_name -- curl -sf http://localhost:${toString ports.services.hyperdxApi}/health" 2>/dev/null || echo "")
                if [[ -n "$hdx_test" ]]; then
                  result_pass "$name pod ready (health endpoint works)"
                  record_result "3" "$name" "pass" "$elapsed"
                else
                  result_warn "$name pod running, health check failed (restarts: $restart_count)"
                  record_result "3" "$name" "warn" "$elapsed"
                fi
              else
                result_warn "$name pod running, waiting for readiness (restarts: $restart_count)"
                record_result "3" "$name" "warn" "$elapsed"
              fi
            else
              result_fail "$name pod not ready (status: $pod_status)"
              record_result "3" "$name" "fail" "$elapsed"
            fi

            # Show brief pod description
            info "  Pod details:"
            _ssh_cmd "kubectl get pods -l $label -n ${namespace} -o wide --no-headers" 2>/dev/null | sed 's/^/    /' || true
          fi
        done

        # Diagnostic: Show all pods status
        step "All pods in namespace:"
        _ssh_cmd "kubectl get pods -n ${namespace} -o wide" 2>/dev/null | sed 's/^/    /' || true

      else
        result_skip "Services check (Minikube not available)"
        record_result "3" "Services" "skip" "0"
        PODS_READY=false
      fi

      # ─── Phase 4: Application Ready ──────────────────────────────────────
      if [[ "$PODS_READY" == "true" ]]; then
        run_phase "4" "Application Ready" "${toString timeouts.applicationReady}"

        step "Waiting for logs..."
        sleep 60

        step "Checking ClickHouse..."
        ${checkFactory.checkClickhouseReady { phase = "4"; }}

        step "Checking log count..."
        ${checkFactory.checkLogCount { phase = "4"; threshold = 0; }}

        # Diagnostic: Show sample log bodies to understand what's being logged
        step "Sample log bodies (for debugging):"
        _ssh_cmd "kubectl exec -n ${namespace} clickhouse-0 -- clickhouse-client -q \"SELECT substring(Body, 1, 80) AS body_sample, count() as cnt FROM otel_logs GROUP BY body_sample ORDER BY cnt DESC LIMIT 5\"" 2>/dev/null | sed 's/^/    /' || true

        step "Verifying FluentBit pipeline..."
        ${checkFactory.checkFluentbitLogs { phase = "4"; threshold = 0; }}

        step "Verifying OTLP pipeline..."
        ${checkFactory.checkOtlpLogs { phase = "4"; threshold = 0; }}

        step "Verifying Filelog pipeline..."
        ${checkFactory.checkFilelogLogs { phase = "4"; threshold = 0; }}

        step "Checking GDP table..."
        ${checkFactory.checkGdpTableExists { phase = "4"; }}

        step "Checking GDP metrics..."
        ${checkFactory.checkGdpMetricCount { phase = "4"; threshold = 0; }}

        step "Checking Kafka consumer..."
        ${checkFactory.checkKafkaHealthy { phase = "4"; }}

        step "Checking HyperDX..."
        ${checkFactory.checkHyperdxReady { phase = "4"; }}
      else
        result_skip "Application check (pods not ready)"
        record_result "4" "Application" "skip" "0"
      fi

      # ─── Phase 5: Shutdown ───────────────────────────────────────────────
      run_phase "5" "Shutdown" "${toString timeouts.shutdown}"
      step "Stopping MicroVM..."
      start_time=$(time_ms)

      # Try graceful shutdown via SSH first
      if [[ "$SSH_READY" == "true" ]]; then
        step "Sending poweroff via SSH..."
        _ssh_cmd "poweroff" 2>/dev/null || true
        sleep 5
      fi

      # Kill process if still running
      if [[ -n "$VM_PID" ]] && kill -0 "$VM_PID" 2>/dev/null; then
        step "Killing VM process..."
        kill "$VM_PID" 2>/dev/null || true
        sleep 2
        if kill -0 "$VM_PID" 2>/dev/null; then
          kill -9 "$VM_PID" 2>/dev/null || true
        fi
      fi

      elapsed=$(elapsed_ms "$start_time")
      result_pass "MicroVM stopped"
      record_result "5" "Shutdown" "pass" "$elapsed"

      # ─── Phase 6: Wait Exit ──────────────────────────────────────────────
      run_phase "6" "Wait Exit" "${toString timeouts.waitExit}"
      step "Verifying VM exited..."
      start_time=$(time_ms)

      sleep 2
      if ! process_running "microvm@otel-demo"; then
        elapsed=$(elapsed_ms "$start_time")
        result_pass "VM process exited"
        record_result "6" "Exit" "pass" "$elapsed"
      else
        elapsed=$(elapsed_ms "$start_time")
        result_fail "VM process still running"
        record_result "6" "Exit" "fail" "$elapsed"
        pkill -9 -f "microvm@otel-demo" 2>/dev/null || true
      fi

      # Clean up files
      rm -f var.img control.sock "$VM_LOG" 2>/dev/null || true

      # ─── Summary ─────────────────────────────────────────────────────────
      trap - EXIT
      print_summary "MicroVM Lifecycle Test"
    '';
  };

  # Individual phase scripts for debugging
  phase-2-ssh = pkgs.writeShellApplication {
    name = "lifecycle-microvm-phase-2";
    runtimeInputs = lifecycleLib.commonInputs ++ lifecycleLib.sshInputs;
    text = ''
      ${lifecycleLib.colorHelpers}
      ${lifecycleLib.sshHelpers}
      ${transports.mkTransport { variant = "microvm"; }}

      bold "Phase 2: SSH Ready"
      echo ""

      if nc -z localhost "${sshPort}" 2>/dev/null; then
        result_pass "SSH port open"
        if transport_ssh_ready; then
          result_pass "SSH authentication works"
        else
          result_fail "SSH authentication failed"
        fi
      else
        result_fail "SSH port not open"
      fi
    '';
  };

  phase-4-application = pkgs.writeShellApplication {
    name = "lifecycle-microvm-phase-4";
    runtimeInputs = lifecycleLib.commonInputs ++ lifecycleLib.sshInputs;
    text = ''
      ${lifecycleLib.colorHelpers}
      ${lifecycleLib.timingHelpers}
      ${lifecycleLib.resultHelpers}
      ${lifecycleLib.sshHelpers}
      ${transports.mkTransport { variant = "microvm"; }}
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
