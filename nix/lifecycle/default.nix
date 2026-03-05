# nix/lifecycle/default.nix
#
# Entry point for lifecycle testing framework.
# Exports all tests, packages, and apps.
#
{ pkgs, lib }:
let
  constants = import ./constants.nix { };
  lifecycleLib = import ./lib.nix { inherit pkgs lib; };

  # Import variant tests
  dockerComposeTest = import ./variants/docker-compose.nix { inherit pkgs lib; };
  minikubeTest = import ./variants/minikube.nix { inherit pkgs lib; };
  microvmTest = import ./variants/microvm.nix { inherit pkgs lib; };

  # Import check modules (for standalone use)
  clickhouseChecks = import ./checks/clickhouse.nix { inherit pkgs lib; };
  gdpChecks = import ./checks/gdp.nix { inherit pkgs lib; };
  hyperdxChecks = import ./checks/hyperdx.nix { inherit pkgs lib; };

  # Test-all orchestrator - uses its own minimal helpers to avoid unused function warnings
  testAll = pkgs.writeShellApplication {
    name = "lifecycle-test-all";
    runtimeInputs = with pkgs; [ coreutils docker minikube procps iproute2 ];
    text = ''
      # Minimal color helpers (only what we use)
      _reset='\033[0m'
      _bold='\033[1m'
      _red='\033[31m'
      _green='\033[32m'
      _cyan='\033[36m'

      info() { echo -e "''${_cyan}$*''${_reset}"; }
      success() { echo -e "''${_green}$*''${_reset}"; }
      error() { echo -e "''${_red}$*''${_reset}"; }
      bold() { echo -e "''${_bold}$*''${_reset}"; }

      # Timing helpers
      time_ms() {
        if date +%s%N >/dev/null 2>&1; then
          echo $(($(date +%s%N) / 1000000))
        else
          echo $(($(date +%s) * 1000))
        fi
      }

      elapsed_ms() {
        local start="$1"
        local now
        now=$(time_ms)
        echo $((now - start))
      }

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

      # Print result row with color
      print_result_row() {
        local name="$1"
        local status="$2"
        local elapsed="$3"
        local color
        if [[ "$status" == "pass" ]]; then
          color="$_green"
        else
          color="$_red"
        fi
        printf "  %-20s ''${color}%-10s''${_reset} %s\n" "$name" "$status" "$(format_ms "$elapsed")"
      }

      bold "═══════════════════════════════════════════════════════════════"
      bold " Lifecycle Tests: All Deployments"
      bold "═══════════════════════════════════════════════════════════════"
      echo ""

      # ─── Pre-flight Cleanup ─────────────────────────────────────────────
      # Clean up any leftover resources from previous runs
      info "Pre-flight cleanup..."

      # 1. Try graceful docker-compose down first (uses nix run)
      if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^otel-"; then
        info "  Running compose-down (graceful)..."
        nix run .#compose-down 2>/dev/null || true
        sleep 2
      fi

      # 2. Force remove any remaining otel-* containers
      otel_containers=$(docker ps -a --format '{{.Names}}' 2>/dev/null | grep "^otel-" || true)
      if [[ -n "$otel_containers" ]]; then
        info "  Force removing leftover containers..."
        echo "$otel_containers" | xargs -r docker rm -f 2>/dev/null || true
      fi

      # 3. Remove otel-demo Docker networks (may have different prefixes)
      for net in $(docker network ls --format '{{.Name}}' 2>/dev/null | grep -E "otel-demo|store_otel" || true); do
        info "  Removing network: $net"
        docker network rm "$net" 2>/dev/null || true
      done

      # 4. Delete any existing minikube cluster
      if minikube status 2>/dev/null | grep -q "Running\|Stopped"; then
        info "  Deleting leftover Minikube cluster..."
        minikube delete 2>/dev/null || true
      fi

      # 5. Kill any microvm processes (identified by microvm@otel-demo)
      if pgrep -f "microvm@otel-demo" >/dev/null 2>&1; then
        info "  Stopping leftover MicroVM..."
        pkill -9 -f "microvm@otel-demo" 2>/dev/null || true
        sleep 2
      fi

      # 6. Check for processes using known compose ports and warn
      COMPOSE_PORTS=(38000 38080 37017 38123 39000 39092 38081 38085 38888 2020)
      ports_in_use=false
      for port in "''${COMPOSE_PORTS[@]}"; do
        if ss -tlnp 2>/dev/null | grep -q ":$port "; then
          error "  Port $port is still in use!"
          ports_in_use=true
        fi
      done

      if [[ "$ports_in_use" == "true" ]]; then
        error "  Some ports are in use. Waiting 5s for release..."
        sleep 5
        # Check again
        for port in "''${COMPOSE_PORTS[@]}"; do
          if ss -tlnp 2>/dev/null | grep -q ":$port "; then
            error "  Port $port still in use after wait - tests may fail"
          fi
        done
      fi

      success "Pre-flight cleanup complete"
      echo ""

      # ─── Pre-build Images ───────────────────────────────────────────────
      # Build all container images once so they're cached for all tests
      info "Pre-building container images (ensures cache for all tests)..."

      # List of images to pre-build (same as minikube.imageNames in constants.nix)
      # NOTE: hyperdx uses upstream Docker Hub image for now
      IMAGES=(loggen fluentbit clickhouse mongodb otel-collector gdp redpanda redpanda-console)

      prebuild_failed=false
      for img in "''${IMAGES[@]}"; do
        if ! nix build ".#''${img}-image" --no-link 2>/dev/null; then
          error "  Failed to build $img-image"
          prebuild_failed=true
        fi
      done

      if [[ "$prebuild_failed" == "true" ]]; then
        error "Some images failed to build - tests may fail"
      else
        success "All images pre-built and cached"
      fi
      echo ""

      TOTAL_PASSED=0
      TOTAL_FAILED=0
      declare -a TEST_RESULTS=()

      run_test() {
        local name="$1"
        local app="$2"
        local start_time
        start_time=$(time_ms)

        info "════════════════════════════════════════"
        info "Running: $name"
        info "════════════════════════════════════════"
        echo ""

        if nix run ".#$app"; then
          local elapsed
          elapsed=$(elapsed_ms "$start_time")
          TEST_RESULTS+=("$name|pass|$elapsed")
          TOTAL_PASSED=$((TOTAL_PASSED + 1))
          success "$name PASSED ($(format_ms "$elapsed"))"
        else
          local elapsed
          elapsed=$(elapsed_ms "$start_time")
          TEST_RESULTS+=("$name|fail|$elapsed")
          TOTAL_FAILED=$((TOTAL_FAILED + 1))
          error "$name FAILED ($(format_ms "$elapsed"))"
        fi
        echo ""
      }

      # Parse arguments
      ONLY=""
      SKIP=""
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --only=*)
            ONLY="''${1#*=}"
            shift
            ;;
          --skip=*)
            SKIP="''${1#*=}"
            shift
            ;;
          --help|-h)
            echo "Usage: lifecycle-test-all [--only=VARIANT] [--skip=VARIANT]"
            echo ""
            echo "Options:"
            echo "  --only=VARIANT   Only run specified variant (docker-compose, minikube, microvm)"
            echo "  --skip=VARIANT   Skip specified variant"
            echo ""
            exit 0
            ;;
          *)
            echo "Unknown option: $1"
            exit 1
            ;;
        esac
      done

      # Run tests
      total_start=$(time_ms)

      should_run() {
        local variant="$1"
        if [[ -n "$ONLY" ]] && [[ "$ONLY" != "$variant" ]]; then
          return 1
        fi
        if [[ -n "$SKIP" ]] && [[ "$SKIP" == "$variant" ]]; then
          return 1
        fi
        return 0
      }

      if should_run "docker-compose"; then
        run_test "Docker Compose" "lifecycle-test-docker-compose"
      fi

      if should_run "minikube"; then
        run_test "Minikube" "lifecycle-test-minikube"
      fi

      if should_run "microvm"; then
        run_test "MicroVM" "lifecycle-test-microvm"
      fi

      # Summary
      total_elapsed=$(elapsed_ms "$total_start")

      bold "═══════════════════════════════════════════════════════════════"
      bold " All Deployment Tests Summary"
      bold "═══════════════════════════════════════════════════════════════"
      echo ""

      # Results table
      printf "  %-20s %-10s %s\n" "Test" "Result" "Time"
      printf "  %-20s %-10s %s\n" "────" "──────" "────"
      for result in "''${TEST_RESULTS[@]}"; do
        IFS='|' read -r name status elapsed <<< "$result"
        print_result_row "$name" "$status" "$elapsed"
      done

      echo ""
      echo "  Total time: $(format_ms "$total_elapsed")"
      echo "  Passed: $TOTAL_PASSED"
      echo "  Failed: $TOTAL_FAILED"
      echo ""

      if [[ $TOTAL_FAILED -gt 0 ]]; then
        error "Some tests failed"
        exit 1
      else
        success "All tests passed!"
        exit 0
      fi
    '';
  };

  # Polling test (unit test for polling helpers)
  testPolling = pkgs.writeShellApplication {
    name = "lifecycle-test-polling";
    runtimeInputs = lifecycleLib.commonInputs;
    text = ''
      ${lifecycleLib.colorHelpers}
      ${lifecycleLib.timingHelpers}
      ${lifecycleLib.pollingHelpers}

      bold "Testing polling helpers..."
      echo ""

      # Test time_ms
      step "Testing time_ms..."
      t1=$(time_ms)
      sleep 0.1
      t2=$(time_ms)
      diff=$((t2 - t1))
      if [[ $diff -ge 50 ]] && [[ $diff -le 500 ]]; then
        result_pass "time_ms works (diff: ''${diff}ms)"
      else
        result_fail "time_ms unexpected diff: ''${diff}ms"
      fi

      # Test format_ms
      step "Testing format_ms..."
      if [[ "$(format_ms 500)" == "500ms" ]]; then
        result_pass "format_ms(500) = 500ms"
      else
        result_fail "format_ms(500) = $(format_ms 500)"
      fi

      if [[ "$(format_ms 1500)" == "1.5s" ]]; then
        result_pass "format_ms(1500) = 1.5s"
      else
        result_fail "format_ms(1500) = $(format_ms 1500)"
      fi

      if [[ "$(format_ms 90000)" == "1m30s" ]]; then
        result_pass "format_ms(90000) = 1m30s"
      else
        result_fail "format_ms(90000) = $(format_ms 90000)"
      fi

      # Test poll_until with quick success
      step "Testing poll_until (quick success)..."
      if elapsed=$(poll_until 5 1 true); then
        result_pass "poll_until quick success (''${elapsed}ms)"
      else
        result_fail "poll_until quick success failed"
      fi

      # Test poll_until with timeout
      step "Testing poll_until (timeout)..."
      if elapsed=$(poll_until 2 1 false); then
        result_fail "poll_until should have timed out"
      else
        if [[ $elapsed -ge 2000 ]] && [[ $elapsed -le 3000 ]]; then
          result_pass "poll_until timeout works (''${elapsed}ms)"
        else
          result_fail "poll_until timeout unexpected: ''${elapsed}ms"
        fi
      fi

      echo ""
      success "Polling tests complete"
    '';
  };

in
{
  # Export constants and library
  inherit constants;
  lib = lifecycleLib;

  # Check modules
  checks = {
    clickhouse = clickhouseChecks;
    gdp = gdpChecks;
    hyperdx = hyperdxChecks;
  };

  # Full lifecycle tests
  tests = {
    docker-compose = dockerComposeTest.test;
    minikube = minikubeTest.test;
    microvm = microvmTest.test;
    all = testAll;
  };

  # Individual phase scripts for debugging
  phases = {
    docker-compose = {
      phase-3 = dockerComposeTest.phase-3-services;
      phase-4 = dockerComposeTest.phase-4-application;
    };
    minikube = {
      phase-3 = minikubeTest.phase-3-services;
      phase-4 = minikubeTest.phase-4-application;
    };
    microvm = {
      phase-2 = microvmTest.phase-2-ssh;
      phase-4 = microvmTest.phase-4-application;
    };
  };

  # Unit tests
  unitTests = {
    polling = testPolling;
  };

  # All packages (flattened for flake outputs)
  packages = {
    lifecycle-test-docker-compose = dockerComposeTest.test;
    lifecycle-test-minikube = minikubeTest.test;
    lifecycle-test-microvm = microvmTest.test;
    lifecycle-test-all = testAll;
    lifecycle-test-polling = testPolling;

    # Phase scripts
    lifecycle-docker-compose-phase-3 = dockerComposeTest.phase-3-services;
    lifecycle-docker-compose-phase-4 = dockerComposeTest.phase-4-application;
    lifecycle-minikube-phase-3 = minikubeTest.phase-3-services;
    lifecycle-minikube-phase-4 = minikubeTest.phase-4-application;
    lifecycle-microvm-phase-2 = microvmTest.phase-2-ssh;
    lifecycle-microvm-phase-4 = microvmTest.phase-4-application;
  };

  # Apps (for nix run)
  apps = builtins.mapAttrs (_name: pkg: {
    type = "app";
    program = lib.getExe pkg;
  }) {
    lifecycle-test-docker-compose = dockerComposeTest.test;
    lifecycle-test-minikube = minikubeTest.test;
    lifecycle-test-microvm = microvmTest.test;
    lifecycle-test-all = testAll;
    lifecycle-test-polling = testPolling;

    # Phase scripts
    lifecycle-docker-compose-phase-3 = dockerComposeTest.phase-3-services;
    lifecycle-docker-compose-phase-4 = dockerComposeTest.phase-4-application;
    lifecycle-minikube-phase-3 = minikubeTest.phase-3-services;
    lifecycle-minikube-phase-4 = minikubeTest.phase-4-application;
    lifecycle-microvm-phase-2 = microvmTest.phase-2-ssh;
    lifecycle-microvm-phase-4 = microvmTest.phase-4-application;
  };
}
