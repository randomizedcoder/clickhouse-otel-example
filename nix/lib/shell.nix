# Shell script utilities for verification and testing scripts
{ lib, pkgs }:
let
  namespace = "otel-demo";

  # Color definitions for terminal output
  colors = ''
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    NC='\033[0m' # No Color
  '';

  # Common shell functions used across verification scripts
  commonFunctions = ''
    ${colors}

    print_header() {
      echo ""
      echo -e "''${BLUE}==============================================''${NC}"
      echo -e "''${BLUE}$1''${NC}"
      echo -e "''${BLUE}==============================================''${NC}"
      echo ""
    }

    print_pass() {
      echo -e "''${GREEN}[PASS]''${NC} $1"
    }

    print_fail() {
      echo -e "''${RED}[FAIL]''${NC} $1"
    }

    print_warn() {
      echo -e "''${YELLOW}[WARN]''${NC} $1"
    }

    print_info() {
      echo -e "''${BLUE}[INFO]''${NC} $1"
    }

    # Wait for a pod to be ready
    wait_for_pod() {
      local label="$1"
      local timeout="''${2:-60}"
      kubectl -n ${namespace} wait --for=condition=ready pod -l "$label" --timeout="''${timeout}s" 2>/dev/null
    }

    # Check if a pod is running
    check_pod_running() {
      local label="$1"
      kubectl -n ${namespace} get pods -l "$label" -o jsonpath='{.items[0].status.phase}' 2>/dev/null | grep -q "Running"
    }

    # Get pod name by label
    get_pod_name() {
      local label="$1"
      kubectl -n ${namespace} get pods -l "$label" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
    }

    # Check if pod is ready (combines running + Ready condition)
    # Usage: check_pod_ready "app=loggen" [timeout_seconds]
    check_pod_ready() {
      local label="$1"
      local timeout="''${2:-60}"
      local pod_name
      pod_name=$(get_pod_name "$label")
      if [ -z "$pod_name" ]; then
        return 1
      fi
      local ready
      ready=$(kubectl -n ${namespace} get pod "$pod_name" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
      [ "$ready" = "True" ]
    }

    # Get pod condition value
    # Usage: get_pod_condition "app=loggen" "Ready"
    get_pod_condition() {
      local label="$1"
      local condition="$2"
      local pod_name
      pod_name=$(get_pod_name "$label")
      kubectl -n ${namespace} get pod "$pod_name" -o jsonpath="{.status.conditions[?(@.type==\"$condition\")].status}" 2>/dev/null || echo ""
    }

    # Get container status field
    # Usage: get_container_status "app=loggen" "ready" (or "restartCount")
    get_container_status() {
      local label="$1"
      local field="$2"
      local pod_name
      pod_name=$(get_pod_name "$label")
      kubectl -n ${namespace} get pod "$pod_name" -o jsonpath="{.status.containerStatuses[0].$field}" 2>/dev/null || echo ""
    }
  '';

  # Test counter functions - reduces boilerplate in verify scripts
  testCounterFunctions = ''
    # Initialize test counters
    init_test_counters() {
      PASSED=0
      FAILED=0
    }

    # Record a test result
    # Usage: record_test "pass" or record_test "fail"
    record_test() {
      if [ "$1" = "pass" ]; then
        PASSED=$((PASSED + 1))
      else
        FAILED=$((FAILED + 1))
      fi
    }

    # Run a check and record result
    # Usage: run_check "description" command_that_returns_0_on_success
    run_check() {
      local description="$1"
      shift
      if "$@"; then
        print_pass "$description"
        PASSED=$((PASSED + 1))
        return 0
      else
        print_fail "$description"
        FAILED=$((FAILED + 1))
        return 1
      fi
    }

    # Print test summary and exit with appropriate code
    print_test_summary() {
      local title="$1"
      echo ""
      print_header "$title"
      echo "Passed: $PASSED"
      echo "Failed: $FAILED"

      if [ "$FAILED" -gt 0 ]; then
        exit 1
      fi
    }
  '';

  # Helper to create a verification script with common boilerplate
  mkVerifyScript = { name, runtimeInputs ? [ pkgs.kubectl pkgs.jq pkgs.curl ], text }:
    pkgs.writeShellApplication {
      inherit name;
      runtimeInputs = runtimeInputs;
      text = ''
        ${commonFunctions}
        ${testCounterFunctions}
        ${text}
      '';
    };

  # Helper to create a break script (failure injection)
  mkBreakScript = { name, description, breakAction, verifyCmd ? null, fixCmd ? null }:
    pkgs.writeShellApplication {
      inherit name;
      runtimeInputs = [ pkgs.kubectl ];
      text = ''
        ${commonFunctions}

        print_header "Breaking ${description}"
        print_info "Injecting failure..."

        ${breakAction}

        print_pass "${description} broken"
        ${lib.optionalString (verifyCmd != null) ''echo "  Run '${verifyCmd}' to verify failure detection"''}
        ${lib.optionalString (fixCmd != null) ''echo "  Run '${fixCmd}' to restore"''}
      '';
    };

  # Helper to create a fix script (restore from failure)
  mkFixScript = { name, description, fixAction, waitAction ? null }:
    pkgs.writeShellApplication {
      inherit name;
      runtimeInputs = [ pkgs.kubectl ];
      text = ''
        ${commonFunctions}

        print_header "Fixing ${description}"
        print_info "Restoring..."

        ${fixAction}

        ${lib.optionalString (waitAction != null) ''
        print_info "Waiting for recovery..."
        ${waitAction}
        ''}

        print_pass "${description} restored"
      '';
    };

in
{
  inherit namespace colors commonFunctions testCounterFunctions;
  inherit mkVerifyScript mkBreakScript mkFixScript;
}
