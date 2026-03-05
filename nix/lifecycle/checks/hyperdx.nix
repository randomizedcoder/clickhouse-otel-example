# nix/lifecycle/checks/hyperdx.nix
#
# HyperDX health check functions.
# Verifies API and app endpoints.
#
# This module now primarily re-exports from the factory for backwards compatibility.
# New code should use the factory directly via transports.
#
{ pkgs, lib }:
let
  constants = import ../constants.nix { };
  factory = import ./factory.nix { inherit pkgs lib; };
in
rec {
  # ─── Legacy Shell Functions ──────────────────────────────────────────────────
  # These are kept for backwards compatibility with existing test scripts.
  # New tests should use the transport abstraction.
  #

  # Check HyperDX API health endpoint
  checkHealthFn = ''
    check_hyperdx_health() {
      local endpoint="$1"
      local result
      result=$(curl -sf "$endpoint${constants.checks.hyperdx.healthPath}" 2>/dev/null)
      echo "$result" | jq -e '.data == "OK"' >/dev/null 2>&1
    }
  '';

  # Check HyperDX app is accessible
  checkAppFn = ''
    check_hyperdx_app() {
      local endpoint="$1"
      curl -sf "$endpoint" >/dev/null 2>&1
    }
  '';

  # Full HyperDX verification
  verifyHyperDxFn = ''
    verify_hyperdx() {
      local api_endpoint="$1"
      local app_endpoint="''${2:-}"
      local phase="''${3:-4}"
      local all_ok=true

      step "Checking HyperDX API..."
      local start_time
      start_time=$(time_ms)
      if check_hyperdx_health "$api_endpoint"; then
        result_pass "HyperDX API healthy"
        record_result "$phase" "HyperDX API" "pass" "$(elapsed_ms "$start_time")"
      else
        result_fail "HyperDX API not healthy"
        record_result "$phase" "HyperDX API" "fail" "$(elapsed_ms "$start_time")"
        all_ok=false
      fi

      if [[ -n "$app_endpoint" ]]; then
        step "Checking HyperDX App..."
        start_time=$(time_ms)
        if check_hyperdx_app "$app_endpoint"; then
          result_pass "HyperDX App accessible"
          record_result "$phase" "HyperDX App" "pass" "$(elapsed_ms "$start_time")"
        else
          result_fail "HyperDX App not accessible"
          record_result "$phase" "HyperDX App" "fail" "$(elapsed_ms "$start_time")"
          all_ok=false
        fi
      fi

      $all_ok
    }
  '';

  # All HyperDX check functions combined
  allCheckFns = ''
    ${checkHealthFn}
    ${checkAppFn}
    ${verifyHyperDxFn}
  '';

  # ─── Kubectl Variants ──────────────────────────────────────────────────────
  # Check HyperDX via kubectl port-forward or NodePort.
  #

  kubectlCheckFns = ''
    kubectl_check_hyperdx_pod() {
      local namespace="$1"
      kubectl get pods -n "$namespace" -l app=hyperdx -o jsonpath='{.items[0].status.phase}' 2>/dev/null | grep -q "Running"
    }

    kubectl_check_hyperdx_ready() {
      local namespace="$1"
      local ready
      ready=$(kubectl get pods -n "$namespace" -l app=hyperdx -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
      [[ "$ready" == "True" ]]
    }
  '';

  # ─── SSH/Remote Variants ──────────────────────────────────────────────────
  # Same checks but using SSH for MicroVM.
  #

  sshCheckFns = ''
    ssh_check_hyperdx_pod() {
      local port="$1"
      local user="$2"
      local pass="$3"
      local namespace="$4"
      local phase
      phase=$(ssh_exec "$port" "$user" "$pass" \
        "kubectl get pods -n $namespace -l app=hyperdx -o jsonpath='{.items[0].status.phase}'" 2>/dev/null | tail -1 | tr -d '[:space:]')
      [[ "$phase" == "Running" ]]
    }

    ssh_check_hyperdx_ready() {
      local port="$1"
      local user="$2"
      local pass="$3"
      local namespace="$4"
      local ready
      ready=$(ssh_exec "$port" "$user" "$pass" \
        "kubectl get pods -n $namespace -l app=hyperdx -o jsonpath='{.items[0].status.conditions[?(@.type==\"Ready\")].status}'" 2>/dev/null | tail -1 | tr -d '[:space:]')
      [[ "$ready" == "True" ]]
    }
  '';

  # Re-export check definitions from factory
  inherit (factory) checkDefs;
}
