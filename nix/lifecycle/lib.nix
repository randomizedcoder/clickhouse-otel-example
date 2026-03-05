# nix/lifecycle/lib.nix
#
# Shell script helpers for lifecycle testing.
# Provides polling-based waits, timing, and color output functions.
#
# These are shell script fragments that get injected into generated scripts.
#
{ pkgs, lib }:
let
  constants = import ./constants.nix { };

  # Common runtime inputs for all lifecycle scripts
  commonInputs = with pkgs; [
    coreutils
    gnugrep
    gnused
    gawk
    procps
    netcat-gnu
    curl
    jq
    bc
    util-linux
  ];

  # Docker-specific inputs
  dockerInputs = with pkgs; [
    docker
  ];

  # Kubernetes-specific inputs
  kubeInputs = with pkgs; [
    kubectl
    minikube
  ];

  # SSH-related inputs (for MicroVM)
  sshInputs = with pkgs; [
    openssh
    sshpass
  ];

  # Expect inputs (for console automation)
  expectInputs = with pkgs; [
    expect
    socat
  ];

  # ─── Color Helpers ──────────────────────────────────────────────────────
  # ANSI color functions for terminal output.
  #
  colorHelpers = ''
    # ANSI color codes
    _reset='\033[0m'
    _bold='\033[1m'
    _red='\033[31m'
    _green='\033[32m'
    _yellow='\033[33m'
    _blue='\033[34m'
    _cyan='\033[36m'
    _magenta='\033[35m'

    # Color output functions
    info() { echo -e "''${_cyan}$*''${_reset}"; }
    success() { echo -e "''${_green}$*''${_reset}"; }
    warn() { echo -e "''${_yellow}$*''${_reset}"; }
    error() { echo -e "''${_red}$*''${_reset}"; }
    bold() { echo -e "''${_bold}$*''${_reset}"; }
    debug() {
      if [[ "''${LIFECYCLE_DEBUG:-}" == "1" ]]; then
        echo -e "''${_magenta}[DEBUG]''${_reset} $*"
      fi
    }

    # Phase header with timeout info
    phase_header() {
      local phase="$1"
      local name="$2"
      local timeout="$3"
      echo ""
      echo -e "''${_bold}═══ Phase $phase: $name (timeout: ''${timeout}s) ═══''${_reset}"
    }

    # Sub-step indicator
    step() {
      echo -e "  ''${_blue}→''${_reset} $*"
    }

    # Pass/fail result with timing
    result_pass() {
      local msg="$1"
      local time_ms="''${2:-}"
      if [[ -n "$time_ms" ]]; then
        echo -e "  ''${_green}✓ PASS''${_reset}: $msg ($(format_ms "$time_ms"))"
      else
        echo -e "  ''${_green}✓ PASS''${_reset}: $msg"
      fi
    }

    result_fail() {
      local msg="$1"
      local time_ms="''${2:-}"
      if [[ -n "$time_ms" ]]; then
        echo -e "  ''${_red}✗ FAIL''${_reset}: $msg ($(format_ms "$time_ms"))"
      else
        echo -e "  ''${_red}✗ FAIL''${_reset}: $msg"
      fi
    }

    result_skip() {
      local msg="$1"
      echo -e "  ''${_yellow}○ SKIP''${_reset}: $msg"
    }

    result_warn() {
      local msg="$1"
      local time_ms="''${2:-}"
      if [[ -n "$time_ms" ]]; then
        echo -e "  ''${_yellow}⚠ WARN''${_reset}: $msg ($(format_ms "$time_ms"))"
      else
        echo -e "  ''${_yellow}⚠ WARN''${_reset}: $msg"
      fi
    }
  '';

  # ─── Timing Helpers ──────────────────────────────────────────────────────
  # Millisecond-precision timing for performance measurement.
  #
  timingHelpers = ''
    # Get current time in milliseconds
    time_ms() {
      # Use date +%s%N for nanoseconds, divide by 1000000 for milliseconds
      # Fall back to seconds * 1000 if nanoseconds not supported
      if date +%s%N >/dev/null 2>&1; then
        echo $(($(date +%s%N) / 1000000))
      else
        echo $(($(date +%s) * 1000))
      fi
    }

    # Calculate elapsed time in milliseconds
    elapsed_ms() {
      local start="$1"
      local now
      now=$(time_ms)
      echo $((now - start))
    }

    # Convert milliseconds to human-readable format
    format_ms() {
      local ms="$1"
      if [[ $ms -lt 1000 ]]; then
        echo "''${ms}ms"
      elif [[ $ms -lt 60000 ]]; then
        local secs=$((ms / 1000))
        local frac=$((ms % 1000 / 100))
        echo "''${secs}.''${frac}s"
      else
        local mins=$((ms / 60000))
        local secs=$(((ms % 60000) / 1000))
        echo "''${mins}m''${secs}s"
      fi
    }
  '';

  # ─── Polling Helpers ──────────────────────────────────────────────────────
  # Generic polling functions that replace hardcoded sleeps.
  #
  pollingHelpers = ''
    # Generic polling function
    # Usage: poll_until <timeout_seconds> <poll_interval> <command...>
    # Returns: 0 if command succeeded, 1 if timeout
    # Outputs: elapsed time in ms on success
    poll_until() {
      local timeout="$1"
      local poll_interval="$2"
      shift 2
      local start_time
      start_time=$(time_ms)
      local elapsed_secs=0

      while [[ $elapsed_secs -lt $timeout ]]; do
        if "$@" >/dev/null 2>&1; then
          elapsed_ms "$start_time"
          return 0
        fi
        sleep "$poll_interval"
        elapsed_secs=$((elapsed_secs + poll_interval))
      done
      elapsed_ms "$start_time"
      return 1
    }

    # Wait for TCP port to be open
    # Usage: wait_for_port <host> <port> <timeout>
    wait_for_port() {
      local host="$1"
      local port="$2"
      local timeout="''${3:-30}"
      local poll_interval="${toString constants.polling.interval}"

      debug "Waiting for port $host:$port (timeout: ''${timeout}s)"
      poll_until "$timeout" "$poll_interval" nc -z "$host" "$port"
    }

    # Wait for HTTP endpoint to return success
    # Usage: wait_for_http <url> <timeout> [expected_content]
    wait_for_http() {
      local url="$1"
      local timeout="''${2:-30}"
      local expected="''${3:-}"
      local poll_interval="${toString constants.polling.interval}"
      local start_time
      start_time=$(time_ms)
      local elapsed_secs=0

      debug "Waiting for HTTP $url (timeout: ''${timeout}s)"

      while [[ $elapsed_secs -lt $timeout ]]; do
        if [[ -n "$expected" ]]; then
          if curl -sf "$url" 2>/dev/null | grep -q "$expected"; then
            elapsed_ms "$start_time"
            return 0
          fi
        else
          if curl -sf "$url" >/dev/null 2>&1; then
            elapsed_ms "$start_time"
            return 0
          fi
        fi
        sleep "$poll_interval"
        elapsed_secs=$((elapsed_secs + poll_interval))
      done
      elapsed_ms "$start_time"
      return 1
    }

    # Wait for ClickHouse query to succeed
    # Usage: wait_for_clickhouse <endpoint> <query> <timeout> [expected]
    wait_for_clickhouse() {
      local endpoint="$1"
      local query="$2"
      local timeout="''${3:-30}"
      local expected="''${4:-}"
      local poll_interval="${toString constants.polling.interval}"
      local start_time
      start_time=$(time_ms)
      local elapsed_secs=0

      debug "Waiting for ClickHouse query (timeout: ''${timeout}s)"

      while [[ $elapsed_secs -lt $timeout ]]; do
        local result
        result=$(curl -sf "$endpoint/" -d "$query" 2>/dev/null || true)
        if [[ -n "$expected" ]]; then
          if [[ "$result" == "$expected" ]]; then
            elapsed_ms "$start_time"
            return 0
          fi
        else
          if [[ -n "$result" ]]; then
            elapsed_ms "$start_time"
            return 0
          fi
        fi
        sleep "$poll_interval"
        elapsed_secs=$((elapsed_secs + poll_interval))
      done
      elapsed_ms "$start_time"
      return 1
    }
  '';

  # ─── Kubernetes Helpers ──────────────────────────────────────────────────
  # Kubernetes-specific polling and verification.
  #
  kubeHelpers = ''
    # Wait for pod to be ready by label
    # Usage: wait_for_pod <namespace> <label> <timeout>
    wait_for_pod() {
      local namespace="$1"
      local label="$2"
      local timeout="''${3:-60}"

      debug "Waiting for pod $label in $namespace (timeout: ''${timeout}s)"
      local start_time
      start_time=$(time_ms)

      if kubectl wait --for=condition=ready pod -l "$label" -n "$namespace" --timeout="''${timeout}s" >/dev/null 2>&1; then
        elapsed_ms "$start_time"
        return 0
      else
        elapsed_ms "$start_time"
        return 1
      fi
    }

    # Check if pod is running by label
    check_pod_running() {
      local namespace="$1"
      local label="$2"
      kubectl get pods -n "$namespace" -l "$label" -o jsonpath='{.items[0].status.phase}' 2>/dev/null | grep -q "Running"
    }

    # Get pod name by label
    get_pod_name() {
      local namespace="$1"
      local label="$2"
      kubectl get pods -n "$namespace" -l "$label" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
    }

    # Execute command in pod
    pod_exec() {
      local namespace="$1"
      local label="$2"
      shift 2
      local pod_name
      pod_name=$(get_pod_name "$namespace" "$label")
      if [[ -n "$pod_name" ]]; then
        kubectl exec -n "$namespace" "$pod_name" -- "$@"
      else
        return 1
      fi
    }
  '';

  # ─── Docker Helpers ──────────────────────────────────────────────────────
  # Docker Compose specific helpers.
  #
  dockerHelpers = ''
    # Check if container is running by name
    check_container_running() {
      local name="$1"
      docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^$name$"
    }

    # Wait for container to be running
    # Usage: wait_for_container <name> <timeout>
    wait_for_container() {
      local name="$1"
      local timeout="''${2:-30}"
      local poll_interval="${toString constants.polling.interval}"

      debug "Waiting for container $name (timeout: ''${timeout}s)"
      poll_until "$timeout" "$poll_interval" check_container_running "$name"
    }

    # Get container logs
    get_container_logs() {
      local name="$1"
      local lines="''${2:-50}"
      docker logs "$name" --tail "$lines" 2>&1
    }
  '';

  # ─── SSH Helpers ──────────────────────────────────────────────────────────
  # SSH-based helpers for MicroVM.
  #
  sshHelpers = ''
    # SSH command wrapper (uses sshpass for password)
    ssh_cmd() {
      local port="$1"
      local user="$2"
      local pass="$3"
      shift 3
      sshpass -p "$pass" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=5 -p "$port" "$user@localhost" "$@"
    }

    # Wait for SSH to be available
    # Usage: wait_for_ssh <port> <user> <pass> <timeout>
    wait_for_ssh() {
      local port="$1"
      local user="$2"
      local pass="$3"
      local timeout="''${4:-60}"
      local poll_interval="${toString constants.polling.slowInterval}"
      local start_time
      start_time=$(time_ms)
      local elapsed_secs=0

      debug "Waiting for SSH on port $port (timeout: ''${timeout}s)"

      while [[ $elapsed_secs -lt $timeout ]]; do
        if ssh_cmd "$port" "$user" "$pass" "echo ok" >/dev/null 2>&1; then
          elapsed_ms "$start_time"
          return 0
        fi
        sleep "$poll_interval"
        elapsed_secs=$((elapsed_secs + poll_interval))
      done
      elapsed_ms "$start_time"
      return 1
    }

    # Execute command via SSH and return output
    ssh_exec() {
      local port="$1"
      local user="$2"
      local pass="$3"
      shift 3
      ssh_cmd "$port" "$user" "$pass" "$@" 2>/dev/null
    }
  '';

  # ─── Console Helpers ──────────────────────────────────────────────────────
  # Console connectivity helpers for MicroVM serial/virtio debugging.
  #
  consoleHelpers = ''
    # Check if console port is accepting connections
    console_port_ready() {
      local port="$1"
      nc -z 127.0.0.1 "$port" 2>/dev/null
    }

    # Wait for console to be ready
    # Usage: wait_for_console <port> <timeout>
    wait_for_console() {
      local port="$1"
      local timeout="''${2:-30}"
      local poll_interval="${toString constants.polling.fastInterval}"
      local start_time
      start_time=$(time_ms)
      local elapsed_secs=0

      debug "Waiting for console on port $port (timeout: ''${timeout}s)"

      while [[ $elapsed_secs -lt $timeout ]]; do
        if console_port_ready "$port"; then
          elapsed_ms "$start_time"
          return 0
        fi
        sleep "$poll_interval"
        elapsed_secs=$((elapsed_secs + poll_interval))
      done
      elapsed_ms "$start_time"
      return 1
    }

    # Dump recent console output for debugging
    # Usage: dump_console_log <port> [timeout]
    dump_console_log() {
      local port="$1"
      local timeout="''${2:-3}"
      echo "--- Console output (port $port) ---"
      timeout "$timeout" socat -u tcp:127.0.0.1:"$port" - 2>/dev/null | tail -50 || true
      echo "--- End console output ---"
    }

    # Read console output without blocking (best effort)
    # Usage: read_console_nonblocking <port>
    read_console_nonblocking() {
      local port="$1"
      # Use timeout with very short duration to grab available data
      timeout 1 socat -u tcp:127.0.0.1:"$port" - 2>/dev/null || true
    }
  '';

  # ─── Process Helpers ──────────────────────────────────────────────────────
  # Process management for VMs and background services.
  #
  processHelpers = ''
    # Check if process is running by pattern
    process_running() {
      local pattern="$1"
      pgrep -f "$pattern" >/dev/null 2>&1
    }

    # Get PID of process by pattern
    get_pid() {
      local pattern="$1"
      pgrep -f "$pattern" 2>/dev/null | head -1
    }

    # Wait for process to start
    wait_for_process() {
      local pattern="$1"
      local timeout="''${2:-30}"
      local poll_interval="${toString constants.polling.interval}"

      debug "Waiting for process '$pattern' (timeout: ''${timeout}s)"
      poll_until "$timeout" "$poll_interval" process_running "$pattern"
    }

    # Wait for process to exit
    wait_for_exit() {
      local pattern="$1"
      local timeout="''${2:-30}"
      local poll_interval="${toString constants.polling.interval}"
      local start_time
      start_time=$(time_ms)
      local elapsed_secs=0

      debug "Waiting for process '$pattern' to exit (timeout: ''${timeout}s)"

      while [[ $elapsed_secs -lt $timeout ]]; do
        if ! process_running "$pattern"; then
          elapsed_ms "$start_time"
          return 0
        fi
        sleep "$poll_interval"
        elapsed_secs=$((elapsed_secs + poll_interval))
      done
      elapsed_ms "$start_time"
      return 1
    }

    # Kill process by pattern
    kill_process() {
      local pattern="$1"
      local pid
      pid=$(get_pid "$pattern")
      if [[ -n "$pid" ]]; then
        kill "$pid" 2>/dev/null || true
        sleep 1
        if process_running "$pattern"; then
          kill -9 "$pid" 2>/dev/null || true
        fi
      fi
    }
  '';

  # ─── Result Tracking ──────────────────────────────────────────────────────
  # Track test results across phases.
  #
  resultHelpers = ''
    # Initialize result tracking
    TOTAL_PASSED=0
    TOTAL_FAILED=0
    TOTAL_SKIPPED=0
    TOTAL_WARNED=0
    declare -a RESULTS=()

    # Record a test result
    record_result() {
      local phase="$1"
      local name="$2"
      local result="$3"
      local elapsed="''${4:-0}"

      RESULTS+=("$phase|$name|$result|$elapsed")

      case "$result" in
        pass) TOTAL_PASSED=$((TOTAL_PASSED + 1)) ;;
        fail) TOTAL_FAILED=$((TOTAL_FAILED + 1)) ;;
        skip) TOTAL_SKIPPED=$((TOTAL_SKIPPED + 1)) ;;
        warn) TOTAL_WARNED=$((TOTAL_WARNED + 1)) ;;
      esac
    }

    # Print results summary table
    print_summary() {
      local title="$1"
      echo ""
      bold "═══════════════════════════════════════════════════════════════"
      bold " $title"
      bold "═══════════════════════════════════════════════════════════════"
      echo ""

      # Print results table
      printf "  %-8s %-30s %-8s %s\n" "Phase" "Check" "Result" "Time"
      printf "  %-8s %-30s %-8s %s\n" "─────" "─────" "──────" "────"

      for result in "''${RESULTS[@]}"; do
        IFS='|' read -r phase name status elapsed <<< "$result"
        local color
        case "$status" in
          pass) color="$_green" ;;
          fail) color="$_red" ;;
          skip) color="$_yellow" ;;
          warn) color="$_yellow" ;;
          *) color="$_reset" ;;
        esac
        printf "  %-8s %-30s ''${color}%-8s''${_reset} %s\n" "$phase" "$name" "$status" "$(format_ms "$elapsed")"
      done

      echo ""
      if [[ $TOTAL_WARNED -gt 0 ]]; then
        echo "  Summary: $TOTAL_PASSED passed, $TOTAL_FAILED failed, $TOTAL_WARNED starting, $TOTAL_SKIPPED skipped"
      else
        echo "  Summary: $TOTAL_PASSED passed, $TOTAL_FAILED failed, $TOTAL_SKIPPED skipped"
      fi
      echo ""

      if [[ $TOTAL_FAILED -gt 0 ]]; then
        error "Some checks failed"
        return 1
      elif [[ $TOTAL_WARNED -gt 0 ]]; then
        warn "Some services still starting (may need more time)"
        return 0
      else
        success "All checks passed!"
        return 0
      fi
    }
  '';

  # ─── Timed Check Helpers ──────────────────────────────────────────────────
  # Unified check execution with timing and recording.
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

  # ─── All Helpers Combined ──────────────────────────────────────────────────
  # Combine all helper functions for easy inclusion.
  #
  allHelpers = ''
    ${colorHelpers}
    ${timingHelpers}
    ${pollingHelpers}
    ${resultHelpers}
    ${timedCheckHelpers}
  '';

in
{
  inherit constants;
  inherit commonInputs dockerInputs kubeInputs sshInputs expectInputs;
  inherit colorHelpers timingHelpers pollingHelpers timedCheckHelpers;
  inherit kubeHelpers dockerHelpers sshHelpers processHelpers consoleHelpers;
  inherit resultHelpers allHelpers;

  # Generate a lifecycle test script with all helpers
  mkLifecycleScript = { name, variant, runtimeInputs ? [], text }:
    let
      variantConfig = constants.variants.${variant};
    in
    pkgs.writeShellApplication {
      inherit name;
      runtimeInputs = commonInputs ++ runtimeInputs;
      text = ''
        # Lifecycle test: ${variant}
        # ${variantConfig.description}

        ${allHelpers}

        # Variant-specific configuration
        VARIANT="${variant}"
        VARIANT_DESC="${variantConfig.description}"

        # Debug mode
        if [[ "''${LIFECYCLE_DEBUG:-}" == "1" ]]; then
          set -x
        fi

        ${text}
      '';
    };
}
