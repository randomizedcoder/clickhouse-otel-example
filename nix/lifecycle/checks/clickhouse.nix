# nix/lifecycle/checks/clickhouse.nix
#
# ClickHouse-specific verification functions.
# Provides shell script fragments for checking ClickHouse health and data.
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

  # Check if ClickHouse is ready (SELECT 1) - HTTP variant
  checkReadyFn = ''
    check_clickhouse_ready() {
      local endpoint="$1"
      local result
      result=$(curl -sf "$endpoint/?query=SELECT+1" 2>/dev/null)
      [[ "$result" == "1" ]]
    }
  '';

  # Check if otel_logs table exists
  checkOtelLogsTableFn = ''
    check_otel_logs_table() {
      local endpoint="$1"
      local result
      result=$(curl -sf "$endpoint/" -d "${constants.checks.clickhouse.otelLogsTable}" 2>/dev/null)
      [[ "$result" == "1" ]]
    }
  '';

  # Get log count
  getLogCountFn = ''
    get_log_count() {
      local endpoint="$1"
      local count
      count=$(curl -sf "$endpoint/" -d "${constants.checks.clickhouse.logCount}" 2>/dev/null)
      echo "''${count:-0}"
    }
  '';

  # Check if logs are growing
  checkLogsGrowingFn = ''
    check_logs_growing() {
      local endpoint="$1"
      local wait_time="''${2:-10}"
      local start_count end_count

      start_count=$(get_log_count "$endpoint")
      sleep "$wait_time"
      end_count=$(get_log_count "$endpoint")

      debug "Log count: $start_count -> $end_count"
      [[ "$end_count" -gt "$start_count" ]]
    }
  '';

  # Check recent logs by pipeline type
  checkPipelineLogsFn = ''
    check_fluentbit_logs() {
      local endpoint="$1"
      local count
      count=$(curl -sf "$endpoint/" -d "${constants.checks.clickhouse.fluentbitLogs}" 2>/dev/null)
      count=''${count:-0}
      [[ "$count" -gt 0 ]] && echo "$count"
    }

    check_otlp_logs() {
      local endpoint="$1"
      local count
      count=$(curl -sf "$endpoint/" -d "${constants.checks.clickhouse.otlpLogs}" 2>/dev/null)
      count=''${count:-0}
      [[ "$count" -gt 0 ]] && echo "$count"
    }

    check_filelog_logs() {
      local endpoint="$1"
      local count
      count=$(curl -sf "$endpoint/" -d "${constants.checks.clickhouse.filelogLogs}" 2>/dev/null)
      count=''${count:-0}
      [[ "$count" -gt 0 ]] && echo "$count"
    }
  '';

  # Verify all pipelines and record results
  verifyAllPipelinesFn = ''
    verify_all_pipelines() {
      local endpoint="$1"
      local phase="''${2:-4}"
      local all_ok=true

      local count
      if count=$(check_fluentbit_logs "$endpoint"); then
        result_pass "FluentBit pipeline: $count logs/min"
        record_result "$phase" "FluentBit logs" "pass" "0"
      else
        result_fail "FluentBit pipeline: no recent logs"
        record_result "$phase" "FluentBit logs" "fail" "0"
        all_ok=false
      fi

      if [[ "$VARIANT" != "docker-compose" ]]; then
        if count=$(check_otlp_logs "$endpoint"); then
          result_pass "OTLP direct pipeline: $count logs/min"
          record_result "$phase" "OTLP logs" "pass" "0"
        else
          result_fail "OTLP direct pipeline: no recent logs"
          record_result "$phase" "OTLP logs" "fail" "0"
          all_ok=false
        fi

        if count=$(check_filelog_logs "$endpoint"); then
          result_pass "Filelog pipeline: $count logs/min"
          record_result "$phase" "Filelog logs" "pass" "0"
        else
          result_fail "Filelog pipeline: no recent logs"
          record_result "$phase" "Filelog logs" "fail" "0"
          all_ok=false
        fi
      fi

      $all_ok
    }
  '';

  # Latency comparison query
  latencyQueryFn = ''
    show_latency_comparison() {
      local endpoint="$1"

      info "Latency comparison by pipeline:"
      echo ""
      curl -sf "$endpoint/" -d "
        SELECT
            multiIf(
                Body LIKE '%FluentBit%', 'fluentbit',
                Body LIKE '%OTLP direct%', 'otlp',
                Body LIKE '%filelog receiver%', 'filelog',
                'unknown'
            ) AS pipeline,
            count() as log_count,
            round(avg(dateDiff('millisecond', Timestamp, IngestionTimestamp)), 0) as avg_latency_ms,
            round(min(dateDiff('millisecond', Timestamp, IngestionTimestamp)), 0) as min_latency_ms,
            round(max(dateDiff('millisecond', Timestamp, IngestionTimestamp)), 0) as max_latency_ms
        FROM otel_logs
        WHERE Timestamp > now() - INTERVAL 5 MINUTE
        GROUP BY pipeline
        ORDER BY avg_latency_ms
        FORMAT PrettyCompact
      " 2>/dev/null || echo "(latency query failed)"
      echo ""
    }
  '';

  # Basic check functions (for standalone phase scripts)
  basicCheckFns = ''
    ${checkReadyFn}
    ${checkOtelLogsTableFn}
    ${getLogCountFn}
    ${checkPipelineLogsFn}
  '';

  # All ClickHouse check functions combined (for full tests that use VARIANT)
  allCheckFns = ''
    ${checkReadyFn}
    ${checkOtelLogsTableFn}
    ${getLogCountFn}
    ${checkLogsGrowingFn}
    ${checkPipelineLogsFn}
    ${verifyAllPipelinesFn}
    ${latencyQueryFn}
  '';

  # ─── Kubectl Variants ──────────────────────────────────────────────────────
  # Same checks but using kubectl exec instead of curl.
  #

  kubectlCheckReadyFn = ''
    kubectl_check_clickhouse_ready() {
      local namespace="$1"
      local result
      result=$(kubectl exec -n "$namespace" clickhouse-0 -- clickhouse-client --query "SELECT 1" 2>/dev/null)
      [[ "$result" == "1" ]]
    }
  '';

  kubectlGetLogCountFn = ''
    kubectl_get_log_count() {
      local namespace="$1"
      local count
      count=$(kubectl exec -n "$namespace" clickhouse-0 -- clickhouse-client --query "SELECT count() FROM otel_logs" 2>/dev/null)
      echo "''${count:-0}"
    }
  '';

  kubectlCheckPipelineLogsFn = ''
    kubectl_check_fluentbit_logs() {
      local namespace="$1"
      local count
      count=$(kubectl exec -n "$namespace" clickhouse-0 -- clickhouse-client --query \
        "SELECT count() FROM otel_logs WHERE Body LIKE '%FluentBit%' AND Timestamp > now() - INTERVAL 1 MINUTE" 2>/dev/null)
      count=''${count:-0}
      [[ "$count" -gt 0 ]] && echo "$count"
    }

    kubectl_check_otlp_logs() {
      local namespace="$1"
      local count
      count=$(kubectl exec -n "$namespace" clickhouse-0 -- clickhouse-client --query \
        "SELECT count() FROM otel_logs WHERE Body LIKE '%OTLP direct%' AND Timestamp > now() - INTERVAL 1 MINUTE" 2>/dev/null)
      count=''${count:-0}
      [[ "$count" -gt 0 ]] && echo "$count"
    }

    kubectl_check_filelog_logs() {
      local namespace="$1"
      local count
      count=$(kubectl exec -n "$namespace" clickhouse-0 -- clickhouse-client --query \
        "SELECT count() FROM otel_logs WHERE Body LIKE '%filelog receiver%' AND Timestamp > now() - INTERVAL 1 MINUTE" 2>/dev/null)
      count=''${count:-0}
      [[ "$count" -gt 0 ]] && echo "$count"
    }
  '';

  kubectlAllCheckFns = ''
    ${kubectlCheckReadyFn}
    ${kubectlGetLogCountFn}
    ${kubectlCheckPipelineLogsFn}
  '';

  # ─── SSH/Remote Variants ──────────────────────────────────────────────────
  # Same checks but using SSH to reach kubectl in MicroVM.
  #

  sshCheckFns = ''
    ssh_check_clickhouse_ready() {
      local port="$1"
      local user="$2"
      local pass="$3"
      local namespace="$4"
      local result
      result=$(ssh_exec "$port" "$user" "$pass" \
        "kubectl exec -n $namespace clickhouse-0 -- clickhouse-client --query 'SELECT 1'" 2>/dev/null | tail -1 | tr -d '[:space:]')
      [[ "$result" == "1" ]]
    }

    ssh_get_log_count() {
      local port="$1"
      local user="$2"
      local pass="$3"
      local namespace="$4"
      local count
      count=$(ssh_exec "$port" "$user" "$pass" \
        "kubectl exec -n $namespace clickhouse-0 -- clickhouse-client --query 'SELECT count() FROM otel_logs'" 2>/dev/null | tail -1 | tr -d '[:space:]')
      echo "''${count:-0}"
    }

    ssh_check_fluentbit_logs() {
      local port="$1"
      local user="$2"
      local pass="$3"
      local namespace="$4"
      local count
      count=$(ssh_exec "$port" "$user" "$pass" \
        "kubectl exec -n $namespace clickhouse-0 -- clickhouse-client --query \"SELECT count() FROM otel_logs WHERE Body LIKE '%FluentBit%' AND Timestamp > now() - INTERVAL 1 MINUTE\"" 2>/dev/null | tail -1 | tr -d '[:space:]')
      count=''${count:-0}
      [[ "$count" -gt 0 ]] && echo "$count"
    }

    ssh_check_otlp_logs() {
      local port="$1"
      local user="$2"
      local pass="$3"
      local namespace="$4"
      local count
      count=$(ssh_exec "$port" "$user" "$pass" \
        "kubectl exec -n $namespace clickhouse-0 -- clickhouse-client --query \"SELECT count() FROM otel_logs WHERE Body LIKE '%OTLP direct%' AND Timestamp > now() - INTERVAL 1 MINUTE\"" 2>/dev/null | tail -1 | tr -d '[:space:]')
      count=''${count:-0}
      [[ "$count" -gt 0 ]] && echo "$count"
    }

    ssh_check_filelog_logs() {
      local port="$1"
      local user="$2"
      local pass="$3"
      local namespace="$4"
      local count
      count=$(ssh_exec "$port" "$user" "$pass" \
        "kubectl exec -n $namespace clickhouse-0 -- clickhouse-client --query \"SELECT count() FROM otel_logs WHERE Body LIKE '%filelog receiver%' AND Timestamp > now() - INTERVAL 1 MINUTE\"" 2>/dev/null | tail -1 | tr -d '[:space:]')
      count=''${count:-0}
      [[ "$count" -gt 0 ]] && echo "$count"
    }
  '';

  # Re-export check definitions from factory
  inherit (factory) checkDefs;
}
