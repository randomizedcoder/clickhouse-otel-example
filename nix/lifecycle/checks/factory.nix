# nix/lifecycle/checks/factory.nix
#
# Parametric check factory for lifecycle tests.
# Creates transport-agnostic check code blocks that work across all deployment variants.
#
# Check definitions are pure data that describe what to check.
# The factory generates inline shell code that uses the transport abstraction.
#
{ pkgs, lib }:
let
  constants = import ../constants.nix { };
in
rec {
  # ─── Check Definitions ─────────────────────────────────────────────────────
  # Pure data describing each check. Transport-agnostic.
  #
  checkDefs = {
    clickhouse = {
      ready = {
        name = "clickhouse_ready";
        description = "ClickHouse responds to SELECT 1";
        query = "SELECT 1";
        expected = "1";
      };
      otelLogsTable = {
        name = "otel_logs_table";
        description = "otel_logs table exists";
        query = constants.checks.clickhouse.otelLogsTable;
        expected = "1";
      };
      logCount = {
        name = "log_count";
        description = "Count logs in ClickHouse";
        query = constants.checks.clickhouse.logCount;
      };
      fluentbitLogs = {
        name = "fluentbit_logs";
        description = "FluentBit pipeline logs";
        query = constants.checks.clickhouse.fluentbitLogs;
      };
      otlpLogs = {
        name = "otlp_logs";
        description = "OTLP pipeline logs";
        query = constants.checks.clickhouse.otlpLogs;
      };
      filelogLogs = {
        name = "filelog_logs";
        description = "Filelog pipeline logs";
        query = constants.checks.clickhouse.filelogLogs;
      };
    };

    gdp = {
      tableExists = {
        name = "gdp_table_exists";
        description = "GDP table exists in ClickHouse";
        query = constants.checks.gdp.tableExists;
        expected = "1";
      };
      metricCount = {
        name = "gdp_metric_count";
        description = "Count GDP metrics";
        query = constants.checks.gdp.metricCount;
      };
      kafkaHealthy = {
        name = "kafka_healthy";
        description = "Kafka consumer has no exceptions";
        query = constants.checks.gdp.kafkaHealthy;
        expected = "0";
      };
    };

    pods = {
      clickhouse = { name = "clickhouse"; label = "app=clickhouse"; };
      mongodb = { name = "mongodb"; label = "app=mongodb"; };
      redpanda = { name = "redpanda"; label = "app=redpanda"; };
      otelCollector = { name = "otel-collector"; label = "app=otel-collector"; };
      fluentbit = { name = "fluentbit"; label = "app=fluentbit"; };
      loggen = { name = "loggen"; label = "app=loggen"; };
      hyperdx = { name = "hyperdx"; label = "app=hyperdx"; };
      gdp = { name = "gdp"; label = "app=gdp"; };
    };
  };

  # ─── ClickHouse Check Code ─────────────────────────────────────────────────
  # Inline code blocks for ClickHouse checks.
  #

  # Check ClickHouse is responding
  checkClickhouseReady = { phase }: ''
    _check_start=$(time_ms)
    _check_result=$(transport_clickhouse_query "SELECT 1" 2>/dev/null || echo "")
    if [[ "$_check_result" == "1" ]]; then
      _check_elapsed=$(elapsed_ms "$_check_start")
      result_pass "ClickHouse"
      record_result "${phase}" "ClickHouse" "pass" "$_check_elapsed"
    else
      _check_elapsed=$(elapsed_ms "$_check_start")
      result_fail "ClickHouse"
      record_result "${phase}" "ClickHouse" "fail" "$_check_elapsed"
    fi
  '';

  # Check otel_logs table exists
  checkOtelLogsTable = { phase }: ''
    _check_start=$(time_ms)
    _check_result=$(transport_clickhouse_query "${checkDefs.clickhouse.otelLogsTable.query}" 2>/dev/null || echo "")
    if [[ "$_check_result" == "1" ]]; then
      _check_elapsed=$(elapsed_ms "$_check_start")
      result_pass "otel_logs table"
      record_result "${phase}" "otel_logs table" "pass" "$_check_elapsed"
    else
      _check_elapsed=$(elapsed_ms "$_check_start")
      result_fail "otel_logs table"
      record_result "${phase}" "otel_logs table" "fail" "$_check_elapsed"
    fi
  '';

  # Check log count > threshold
  checkLogCount = { phase, threshold ? 0 }: ''
    _check_start=$(time_ms)
    _check_value=$(transport_clickhouse_query "${checkDefs.clickhouse.logCount.query}" 2>/dev/null || echo "0")
    _check_value=''${_check_value:-0}
    _check_elapsed=$(elapsed_ms "$_check_start")
    if [[ "$_check_value" -gt ${toString threshold} ]]; then
      result_pass "Log count: $_check_value"
      record_result "${phase}" "Log count" "pass" "$_check_elapsed"
    else
      result_fail "Log count: $_check_value (need > ${toString threshold})"
      record_result "${phase}" "Log count" "fail" "$_check_elapsed"
    fi
  '';

  # Check FluentBit logs > threshold
  checkFluentbitLogs = { phase, threshold ? 0 }: ''
    _check_start=$(time_ms)
    _check_value=$(transport_clickhouse_query "${checkDefs.clickhouse.fluentbitLogs.query}" 2>/dev/null || echo "0")
    _check_value=''${_check_value:-0}
    _check_elapsed=$(elapsed_ms "$_check_start")
    if [[ "$_check_value" -gt ${toString threshold} ]]; then
      result_pass "FluentBit logs: $_check_value"
      record_result "${phase}" "FluentBit logs" "pass" "$_check_elapsed"
    else
      result_fail "FluentBit logs: $_check_value (need > ${toString threshold})"
      record_result "${phase}" "FluentBit logs" "fail" "$_check_elapsed"
    fi
  '';

  # Check OTLP logs > threshold
  checkOtlpLogs = { phase, threshold ? 0 }: ''
    _check_start=$(time_ms)
    _check_value=$(transport_clickhouse_query "${checkDefs.clickhouse.otlpLogs.query}" 2>/dev/null || echo "0")
    _check_value=''${_check_value:-0}
    _check_elapsed=$(elapsed_ms "$_check_start")
    if [[ "$_check_value" -gt ${toString threshold} ]]; then
      result_pass "OTLP logs: $_check_value"
      record_result "${phase}" "OTLP logs" "pass" "$_check_elapsed"
    else
      result_fail "OTLP logs: $_check_value (need > ${toString threshold})"
      record_result "${phase}" "OTLP logs" "fail" "$_check_elapsed"
    fi
  '';

  # Check Filelog logs > threshold
  checkFilelogLogs = { phase, threshold ? 0 }: ''
    _check_start=$(time_ms)
    _check_value=$(transport_clickhouse_query "${checkDefs.clickhouse.filelogLogs.query}" 2>/dev/null || echo "0")
    _check_value=''${_check_value:-0}
    _check_elapsed=$(elapsed_ms "$_check_start")
    if [[ "$_check_value" -gt ${toString threshold} ]]; then
      result_pass "Filelog logs: $_check_value"
      record_result "${phase}" "Filelog logs" "pass" "$_check_elapsed"
    else
      result_fail "Filelog logs: $_check_value (need > ${toString threshold})"
      record_result "${phase}" "Filelog logs" "fail" "$_check_elapsed"
    fi
  '';

  # ─── GDP Check Code ────────────────────────────────────────────────────────
  # Inline code blocks for GDP checks.
  #

  # Check GDP table exists
  checkGdpTableExists = { phase }: ''
    _check_start=$(time_ms)
    _check_result=$(transport_clickhouse_query "${checkDefs.gdp.tableExists.query}" 2>/dev/null || echo "")
    if [[ "$_check_result" == "1" ]]; then
      _check_elapsed=$(elapsed_ms "$_check_start")
      result_pass "GDP table"
      record_result "${phase}" "GDP table" "pass" "$_check_elapsed"
    else
      _check_elapsed=$(elapsed_ms "$_check_start")
      result_fail "GDP table"
      record_result "${phase}" "GDP table" "fail" "$_check_elapsed"
    fi
  '';

  # Check GDP metrics > threshold
  checkGdpMetricCount = { phase, threshold ? 0 }: ''
    _check_start=$(time_ms)
    _check_value=$(transport_clickhouse_query "${checkDefs.gdp.metricCount.query}" 2>/dev/null || echo "0")
    _check_value=''${_check_value:-0}
    _check_elapsed=$(elapsed_ms "$_check_start")
    if [[ "$_check_value" -gt ${toString threshold} ]]; then
      result_pass "GDP metrics: $_check_value"
      record_result "${phase}" "GDP metrics" "pass" "$_check_elapsed"
    else
      result_fail "GDP metrics: $_check_value (need > ${toString threshold})"
      record_result "${phase}" "GDP metrics" "fail" "$_check_elapsed"
    fi
  '';

  # Check Kafka consumer healthy
  checkKafkaHealthy = { phase }: ''
    _check_start=$(time_ms)
    _check_result=$(transport_clickhouse_query "${checkDefs.gdp.kafkaHealthy.query}" 2>/dev/null || echo "")
    if [[ "$_check_result" == "0" ]]; then
      _check_elapsed=$(elapsed_ms "$_check_start")
      result_pass "Kafka"
      record_result "${phase}" "Kafka" "pass" "$_check_elapsed"
    else
      _check_elapsed=$(elapsed_ms "$_check_start")
      result_fail "Kafka (exceptions: $_check_result)"
      record_result "${phase}" "Kafka" "fail" "$_check_elapsed"
      # Show kafka consumer details for debugging
      info "  Kafka consumers status:"
      transport_clickhouse_query "SELECT database, table, name, num_messages_read, exceptions.text FROM system.kafka_consumers FORMAT Vertical" 2>/dev/null | head -30 | sed 's/^/    /' || true
    fi
  '';

  # ─── HyperDX Check Code ────────────────────────────────────────────────────
  # Inline code blocks for HyperDX checks.
  #

  # Check HyperDX is ready
  checkHyperdxReady = { phase }: ''
    _check_start=$(time_ms)
    if transport_hyperdx_health; then
      _check_elapsed=$(elapsed_ms "$_check_start")
      result_pass "HyperDX"
      record_result "${phase}" "HyperDX" "pass" "$_check_elapsed"
    else
      _check_elapsed=$(elapsed_ms "$_check_start")
      result_fail "HyperDX"
      record_result "${phase}" "HyperDX" "fail" "$_check_elapsed"
    fi
  '';

  # ─── Container/Pod Check Code ──────────────────────────────────────────────
  # Inline code blocks for container and pod checks.
  #

  # Check container is running
  checkContainerRunning = { phase, name, containerName }: ''
    _check_start=$(time_ms)
    if transport_check_container_running "${containerName}"; then
      _check_elapsed=$(elapsed_ms "$_check_start")
      result_pass "${name}"
      record_result "${phase}" "${name}" "pass" "$_check_elapsed"
    else
      _check_elapsed=$(elapsed_ms "$_check_start")
      result_fail "${name}"
      record_result "${phase}" "${name}" "fail" "$_check_elapsed"
    fi
  '';

  # Check pod is ready
  checkPodReady = { phase, name, label }: ''
    _check_start=$(time_ms)
    if transport_check_pod_ready "${label}"; then
      _check_elapsed=$(elapsed_ms "$_check_start")
      result_pass "${name}"
      record_result "${phase}" "${name}" "pass" "$_check_elapsed"
    else
      _check_elapsed=$(elapsed_ms "$_check_start")
      result_fail "${name}"
      record_result "${phase}" "${name}" "fail" "$_check_elapsed"
    fi
  '';

  # Wait for pod with timeout
  waitForPod = { phase, name, label, timeout ? 60 }: ''
    _check_start=$(time_ms)
    if transport_wait_for_pod "${label}" "${toString timeout}"; then
      _check_elapsed=$(elapsed_ms "$_check_start")
      result_pass "${name}"
      record_result "${phase}" "${name}" "pass" "$_check_elapsed"
    else
      _check_elapsed=$(elapsed_ms "$_check_start")
      result_fail "${name}"
      record_result "${phase}" "${name}" "fail" "$_check_elapsed"
    fi
  '';

  # ─── Nix Command Check Code ────────────────────────────────────────────────
  # Inline code blocks for running nix commands.
  #

  # Run a nix command as a check
  checkNixCommand = { phase, name, command }: ''
    _check_start=$(time_ms)
    if ${command}; then
      _check_elapsed=$(elapsed_ms "$_check_start")
      result_pass "${name}"
      record_result "${phase}" "${name}" "pass" "$_check_elapsed"
    else
      _check_elapsed=$(elapsed_ms "$_check_start")
      result_fail "${name}"
      record_result "${phase}" "${name}" "fail" "$_check_elapsed"
    fi
  '';

  # ─── Polling Wait Functions ────────────────────────────────────────────────
  # Wait for services with timeout and polling.
  #

  # Wait for ClickHouse to respond to SELECT 1
  waitForClickhouse = { phase, timeout ? 120 }: ''
    _check_start=$(time_ms)
    _wait_timeout=${toString timeout}
    _wait_elapsed=0
    _poll_interval=2

    step "Waiting for ClickHouse to be ready (timeout: ''${_wait_timeout}s)..."

    while [[ $_wait_elapsed -lt $_wait_timeout ]]; do
      _result=$(transport_clickhouse_query "SELECT 1" 2>/dev/null || echo "")
      if [[ "$_result" == "1" ]]; then
        _check_elapsed=$(elapsed_ms "$_check_start")
        result_pass "ClickHouse ready"
        record_result "${phase}" "ClickHouse ready" "pass" "$_check_elapsed"
        break
      fi
      debug "ClickHouse not ready yet (''${_wait_elapsed}s/''${_wait_timeout}s)"
      sleep "$_poll_interval"
      _wait_elapsed=$((_wait_elapsed + _poll_interval))
    done

    if [[ $_wait_elapsed -ge $_wait_timeout ]]; then
      _check_elapsed=$(elapsed_ms "$_check_start")
      result_fail "ClickHouse not ready (timeout)"
      record_result "${phase}" "ClickHouse ready" "fail" "$_check_elapsed"
    fi
  '';

  # Check if a specific table exists
  checkTableExists = { phase, database, table }: ''
    _check_start=$(time_ms)
    _result=$(transport_clickhouse_query "SELECT count() FROM system.tables WHERE database='${database}' AND name='${table}'" 2>/dev/null || echo "")
    if [[ "$_result" == "1" ]]; then
      _check_elapsed=$(elapsed_ms "$_check_start")
      result_pass "${database}.${table} exists"
      record_result "${phase}" "${database}.${table}" "pass" "$_check_elapsed"
    else
      _check_elapsed=$(elapsed_ms "$_check_start")
      result_fail "${database}.${table} not found"
      record_result "${phase}" "${database}.${table}" "fail" "$_check_elapsed"
    fi
  '';

  # Check Kafka consumer tables are healthy (no exceptions)
  checkKafkaConsumersHealthy = { phase }: ''
    _check_start=$(time_ms)
    _result=$(transport_clickhouse_query "SELECT countIf(length(exceptions.text) > 0) FROM system.kafka_consumers" 2>/dev/null || echo "")
    if [[ "$_result" == "0" ]]; then
      _check_elapsed=$(elapsed_ms "$_check_start")
      result_pass "Kafka consumers healthy"
      record_result "${phase}" "Kafka consumers" "pass" "$_check_elapsed"
    else
      _check_elapsed=$(elapsed_ms "$_check_start")
      result_fail "Kafka consumers have exceptions: $_result"
      record_result "${phase}" "Kafka consumers" "fail" "$_check_elapsed"
    fi
  '';

  # Wait for a table to exist with timeout
  waitForTable = { phase, database, table, timeout ? 60 }: ''
    _check_start=$(time_ms)
    _wait_timeout=${toString timeout}
    _wait_elapsed=0
    _poll_interval=2

    while [[ $_wait_elapsed -lt $_wait_timeout ]]; do
      _result=$(transport_clickhouse_query "SELECT count() FROM system.tables WHERE database='${database}' AND name='${table}'" 2>/dev/null || echo "")
      if [[ "$_result" == "1" ]]; then
        _check_elapsed=$(elapsed_ms "$_check_start")
        result_pass "${database}.${table} exists"
        record_result "${phase}" "${database}.${table}" "pass" "$_check_elapsed"
        break
      fi
      debug "Table ${database}.${table} not found yet (''${_wait_elapsed}s/''${_wait_timeout}s)"
      sleep "$_poll_interval"
      _wait_elapsed=$((_wait_elapsed + _poll_interval))
    done

    if [[ $_wait_elapsed -ge $_wait_timeout ]]; then
      _check_elapsed=$(elapsed_ms "$_check_start")
      result_fail "${database}.${table} not found (timeout)"
      record_result "${phase}" "${database}.${table}" "fail" "$_check_elapsed"
    fi
  '';

  # ─── Utility Functions ─────────────────────────────────────────────────────
  # Helper functions that ARE called directly (not via run_check).
  #

  utilityFunctions = ''
    # Get log count (returns value, not boolean)
    get_log_count() {
      local result
      result=$(transport_clickhouse_query "${checkDefs.clickhouse.logCount.query}" 2>/dev/null)
      echo "''${result:-0}"
    }

    # Get GDP metric count
    get_gdp_count() {
      local result
      result=$(transport_clickhouse_query "${checkDefs.gdp.metricCount.query}" 2>/dev/null)
      echo "''${result:-0}"
    }

    # Check if logs are growing over time
    check_logs_growing() {
      local wait_time="''${1:-10}"
      local start_count end_count

      start_count=$(get_log_count)
      sleep "$wait_time"
      end_count=$(get_log_count)

      debug "Log count: $start_count -> $end_count"
      [[ "$end_count" -gt "$start_count" ]]
    }

    # Check if GDP metrics are growing over time
    check_gdp_growing() {
      local wait_time="''${1:-15}"
      local start_count end_count

      start_count=$(get_gdp_count)
      sleep "$wait_time"
      end_count=$(get_gdp_count)

      debug "GDP count: $start_count -> $end_count"
      [[ "$end_count" -gt "$start_count" ]]
    }
  '';

}
