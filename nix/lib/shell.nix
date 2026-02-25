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
  '';

  # Helper to create a verification script with common boilerplate
  mkVerifyScript = { name, runtimeInputs ? [ pkgs.kubectl pkgs.jq pkgs.curl ], text }:
    pkgs.writeShellApplication {
      inherit name;
      runtimeInputs = runtimeInputs;
      text = ''
        ${commonFunctions}
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
        print_info "${breakAction}"

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
        print_info "${fixAction}"

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
  inherit namespace colors commonFunctions;
  inherit mkVerifyScript mkBreakScript mkFixScript;
}
