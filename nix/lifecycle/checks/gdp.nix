# nix/lifecycle/checks/gdp.nix
#
# GDP pipeline verification functions.
# Checks for Kafka/Redpanda health and GDP metrics in ClickHouse.
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

  # Check if GDP table exists in ClickHouse
  checkGdpTableFn = ''
    check_gdp_table_exists() {
      local endpoint="$1"
      local result
      result=$(curl -sf "$endpoint/" -d "${constants.checks.gdp.tableExists}" 2>/dev/null)
      [[ "$result" == "1" ]]
    }
  '';

  # Get GDP metric count
  getGdpCountFn = ''
    get_gdp_count() {
      local endpoint="$1"
      local count
      count=$(curl -sf "$endpoint/" -d "${constants.checks.gdp.metricCount}" 2>/dev/null)
      echo "''${count:-0}"
    }
  '';

  # Check if GDP metrics are growing
  checkGdpGrowingFn = ''
    check_gdp_growing() {
      local endpoint="$1"
      local wait_time="''${2:-15}"
      local start_count end_count

      start_count=$(get_gdp_count "$endpoint")
      sleep "$wait_time"
      end_count=$(get_gdp_count "$endpoint")

      debug "GDP count: $start_count -> $end_count"
      [[ "$end_count" -gt "$start_count" ]]
    }
  '';

  # Check Kafka consumer health (no exceptions)
  checkKafkaHealthyFn = ''
    check_kafka_healthy() {
      local endpoint="$1"
      local exceptions
      exceptions=$(curl -sf "$endpoint/" -d "${constants.checks.gdp.kafkaHealthy}" 2>/dev/null)
      exceptions=''${exceptions:-0}
      [[ "$exceptions" == "0" ]]
    }
  '';

  # Full GDP pipeline verification
  verifyGdpPipelineFn = ''
    verify_gdp_pipeline() {
      local endpoint="$1"
      local phase="''${2:-4}"
      local all_ok=true

      step "Checking GDP table..."
      local start_time
      start_time=$(time_ms)
      if check_gdp_table_exists "$endpoint"; then
        result_pass "GDP table gdp.ProtobufSingle exists"
        record_result "$phase" "GDP table" "pass" "$(elapsed_ms "$start_time")"
      else
        result_fail "GDP table not found"
        record_result "$phase" "GDP table" "fail" "$(elapsed_ms "$start_time")"
        all_ok=false
      fi

      step "Checking GDP metrics..."
      start_time=$(time_ms)
      local gdp_count
      gdp_count=$(get_gdp_count "$endpoint")
      if [[ "$gdp_count" -gt 0 ]]; then
        result_pass "GDP metrics in ClickHouse: $gdp_count"
        record_result "$phase" "GDP metrics" "pass" "$(elapsed_ms "$start_time")"
      else
        result_fail "No GDP metrics in ClickHouse"
        record_result "$phase" "GDP metrics" "fail" "$(elapsed_ms "$start_time")"
        all_ok=false
      fi

      step "Checking GDP metrics growing..."
      start_time=$(time_ms)
      if check_gdp_growing "$endpoint" 15; then
        result_pass "GDP metrics increasing"
        record_result "$phase" "GDP growing" "pass" "$(elapsed_ms "$start_time")"
      else
        result_fail "GDP metrics not increasing"
        record_result "$phase" "GDP growing" "fail" "$(elapsed_ms "$start_time")"
        all_ok=false
      fi

      step "Checking Kafka consumer..."
      start_time=$(time_ms)
      if check_kafka_healthy "$endpoint"; then
        result_pass "Kafka consumer healthy (no exceptions)"
        record_result "$phase" "Kafka consumer" "pass" "$(elapsed_ms "$start_time")"
      else
        result_fail "Kafka consumer has exceptions"
        record_result "$phase" "Kafka consumer" "fail" "$(elapsed_ms "$start_time")"
        all_ok=false
      fi

      $all_ok
    }
  '';

  # Basic GDP check functions (for standalone phase scripts)
  basicCheckFns = ''
    ${checkGdpTableFn}
    ${getGdpCountFn}
  '';

  # All GDP check functions combined (for full tests)
  allCheckFns = ''
    ${checkGdpTableFn}
    ${getGdpCountFn}
    ${checkGdpGrowingFn}
    ${checkKafkaHealthyFn}
    ${verifyGdpPipelineFn}
  '';

  # ─── Kubectl Variants ──────────────────────────────────────────────────────
  # Same checks but using kubectl exec.
  #

  kubectlCheckFns = ''
    kubectl_check_gdp_table() {
      local namespace="$1"
      local result
      result=$(kubectl exec -n "$namespace" clickhouse-0 -- clickhouse-client --query \
        "SELECT count() FROM system.tables WHERE database='gdp' AND name='ProtobufSingle'" 2>/dev/null)
      [[ "$result" == "1" ]]
    }

    kubectl_get_gdp_count() {
      local namespace="$1"
      local count
      count=$(kubectl exec -n "$namespace" clickhouse-0 -- clickhouse-client --query \
        "SELECT count() FROM gdp.ProtobufSingle" 2>/dev/null)
      echo "''${count:-0}"
    }

    kubectl_check_kafka_healthy() {
      local namespace="$1"
      local exceptions
      exceptions=$(kubectl exec -n "$namespace" clickhouse-0 -- clickhouse-client --query \
        "SELECT countIf(length(exceptions.text)>0) FROM system.kafka_consumers" 2>/dev/null)
      exceptions=''${exceptions:-0}
      [[ "$exceptions" == "0" ]]
    }
  '';

  # ─── SSH/Remote Variants ──────────────────────────────────────────────────
  # Same checks but using SSH for MicroVM.
  #

  sshCheckFns = ''
    ssh_check_gdp_table() {
      local port="$1"
      local user="$2"
      local pass="$3"
      local namespace="$4"
      local result
      result=$(ssh_exec "$port" "$user" "$pass" \
        "kubectl exec -n $namespace clickhouse-0 -- clickhouse-client --query \"SELECT count() FROM system.tables WHERE database='gdp' AND name='ProtobufSingle'\"" 2>/dev/null | tail -1 | tr -d '[:space:]')
      [[ "$result" == "1" ]]
    }

    ssh_get_gdp_count() {
      local port="$1"
      local user="$2"
      local pass="$3"
      local namespace="$4"
      local count
      count=$(ssh_exec "$port" "$user" "$pass" \
        "kubectl exec -n $namespace clickhouse-0 -- clickhouse-client --query 'SELECT count() FROM gdp.ProtobufSingle'" 2>/dev/null | tail -1 | tr -d '[:space:]')
      echo "''${count:-0}"
    }

    ssh_check_kafka_healthy() {
      local port="$1"
      local user="$2"
      local pass="$3"
      local namespace="$4"
      local exceptions
      exceptions=$(ssh_exec "$port" "$user" "$pass" \
        "kubectl exec -n $namespace clickhouse-0 -- clickhouse-client --query 'SELECT countIf(length(exceptions.text)>0) FROM system.kafka_consumers'" 2>/dev/null | tail -1 | tr -d '[:space:]')
      exceptions=''${exceptions:-0}
      [[ "$exceptions" == "0" ]]
    }
  '';

  # Re-export check definitions from factory
  inherit (factory) checkDefs;
}
