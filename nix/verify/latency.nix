# Latency measurement scripts
{ pkgs, shellLib }:
let
  inherit (shellLib) namespace commonFunctions mkVerifyScript;
in
{
  measure-latency = mkVerifyScript {
    name = "measure-latency";
    runtimeInputs = with pkgs; [ kubectl bc gawk ];
    text = ''
      print_header "Pipeline Latency Measurement"

      SAMPLES=''${1:-10}
      WINDOW_SECONDS=60

      echo "Measuring end-to-end latency from log emission to ClickHouse availability"
      echo "  Samples: $SAMPLES most recent logs"
      echo "  Window: logs from last $WINDOW_SECONDS seconds"
      echo ""

      # Check ClickHouse is available
      print_info "Connecting to ClickHouse..."
      CH_POD=$(get_pod_name "app=clickhouse")

      if [ -z "$CH_POD" ]; then
        print_fail "ClickHouse pod not found"
        exit 1
      fi

      # Verify ClickHouse is responding
      if ! kubectl -n ${namespace} exec "$CH_POD" -- clickhouse-client --query "SELECT 1" >/dev/null 2>&1; then
        print_fail "ClickHouse not responding"
        exit 1
      fi
      print_pass "Connected to ClickHouse pod: $CH_POD"

      # Check if otel_logs table has data
      RECORD_COUNT=$(kubectl -n ${namespace} exec "$CH_POD" -- clickhouse-client --query "SELECT count() FROM otel_logs" 2>/dev/null || echo "0")
      if [ "$RECORD_COUNT" = "0" ]; then
        print_fail "No records in otel_logs table"
        exit 1
      fi
      print_info "Total records in otel_logs: $RECORD_COUNT"

      echo ""
      print_header "Passive Latency Measurement"
      echo "Analyzing age of recent logs (current_time - log_timestamp)..."
      echo ""

      # Query recent logs and calculate their age
      # The Timestamp column contains the time when loggen emitted the log
      # We compare it to ClickHouse's current time (now64)
      LATENCY_DATA=$(kubectl -n ${namespace} exec "$CH_POD" -- clickhouse-client --query "
        SELECT
          toFloat64(now64(3) - Timestamp) as age_seconds,
          Timestamp,
          Count
        FROM otel_logs
        WHERE Timestamp > now() - INTERVAL $WINDOW_SECONDS SECOND
        ORDER BY Timestamp DESC
        LIMIT $SAMPLES
      " 2>/dev/null || echo "")

      if [ -z "$LATENCY_DATA" ]; then
        print_warn "No recent logs found in the last $WINDOW_SECONDS seconds"
        echo "  The log generator may not be running or FluentBit may not be forwarding logs"
        exit 1
      fi

      # Display sample data
      print_info "Recent log latencies (newest first):"
      echo ""
      printf "  %-12s %-30s %s\n" "AGE (sec)" "TIMESTAMP" "COUNT"
      printf "  %-12s %-30s %s\n" "--------" "---------" "-----"
      echo "$LATENCY_DATA" | head -5 | while IFS=$'\t' read -r age ts count; do
        printf "  %-12.3f %-30s %s\n" "$age" "$ts" "$count"
      done
      echo ""

      # Calculate statistics using awk
      STATS=$(echo "$LATENCY_DATA" | awk -F'\t' '
        BEGIN {
          min = 999999
          max = 0
          sum = 0
          count = 0
        }
        {
          age = $1
          if (age < min) min = age
          if (age > max) max = age
          sum += age
          count++
          # Store values for percentile calculation
          values[count] = age
        }
        END {
          if (count == 0) {
            print "ERROR: No data"
            exit 1
          }
          avg = sum / count

          # Sort values for percentiles (simple bubble sort for small datasets)
          for (i = 1; i <= count; i++) {
            for (j = i + 1; j <= count; j++) {
              if (values[i] > values[j]) {
                tmp = values[i]
                values[i] = values[j]
                values[j] = tmp
              }
            }
          }

          # Calculate percentiles
          p50_idx = int(count * 0.5) + 1
          p90_idx = int(count * 0.9) + 1
          p99_idx = int(count * 0.99) + 1
          if (p50_idx > count) p50_idx = count
          if (p90_idx > count) p90_idx = count
          if (p99_idx > count) p99_idx = count

          printf "samples=%d\n", count
          printf "min=%.3f\n", min
          printf "max=%.3f\n", max
          printf "avg=%.3f\n", avg
          printf "p50=%.3f\n", values[p50_idx]
          printf "p90=%.3f\n", values[p90_idx]
          printf "p99=%.3f\n", values[p99_idx]
        }
      ')

      # Parse statistics
      SAMPLE_COUNT=$(echo "$STATS" | grep "^samples=" | cut -d= -f2)
      MIN_LATENCY=$(echo "$STATS" | grep "^min=" | cut -d= -f2)
      MAX_LATENCY=$(echo "$STATS" | grep "^max=" | cut -d= -f2)
      AVG_LATENCY=$(echo "$STATS" | grep "^avg=" | cut -d= -f2)
      P50_LATENCY=$(echo "$STATS" | grep "^p50=" | cut -d= -f2)
      P90_LATENCY=$(echo "$STATS" | grep "^p90=" | cut -d= -f2)
      P99_LATENCY=$(echo "$STATS" | grep "^p99=" | cut -d= -f2)

      # Display statistics
      print_header "Latency Statistics"
      echo ""
      printf "  %-20s %s\n" "Samples analyzed:" "$SAMPLE_COUNT"
      printf "  %-20s %s\n" "Window:" "Last $WINDOW_SECONDS seconds"
      echo ""
      printf "  %-20s %.3f seconds\n" "Minimum (freshest):" "$MIN_LATENCY"
      printf "  %-20s %.3f seconds\n" "Maximum (oldest):" "$MAX_LATENCY"
      printf "  %-20s %.3f seconds\n" "Average:" "$AVG_LATENCY"
      echo ""
      printf "  %-20s %.3f seconds\n" "P50 (median):" "$P50_LATENCY"
      printf "  %-20s %.3f seconds\n" "P90:" "$P90_LATENCY"
      printf "  %-20s %.3f seconds\n" "P99:" "$P99_LATENCY"
      echo ""

      # Interpretation
      print_header "Interpretation"
      echo ""
      echo "The latency includes:"
      echo "  1. Container runtime writing log to file"
      echo "  2. FluentBit tail refresh interval (configured: 5s)"
      echo "  3. FluentBit processing (Lua transformation)"
      echo "  4. FluentBit flush interval (configured: 1s)"
      echo "  5. Network transfer to ClickHouse"
      echo "  6. ClickHouse write and indexing"
      echo ""

      # Provide assessment
      if [ "$(echo "$AVG_LATENCY < 10" | bc -l)" = "1" ]; then
        print_pass "Average latency is excellent (< 10s)"
      elif [ "$(echo "$AVG_LATENCY < 30" | bc -l)" = "1" ]; then
        print_pass "Average latency is good (< 30s)"
      elif [ "$(echo "$AVG_LATENCY < 60" | bc -l)" = "1" ]; then
        print_warn "Average latency is moderate (< 60s)"
      else
        print_warn "Average latency is high (> 60s)"
        echo "  Consider checking FluentBit buffer settings and ClickHouse performance"
      fi
      echo ""
    '';
  };

  measure-latency-active = mkVerifyScript {
    name = "measure-latency-active";
    runtimeInputs = with pkgs; [ kubectl bc gawk coreutils ];
    text = ''
      print_header "Active Pipeline Latency Measurement"

      SAMPLES=''${1:-5}
      TIMEOUT=30

      echo "Actively measuring latency by waiting for new logs to appear"
      echo "  Samples to collect: $SAMPLES"
      echo "  Timeout per sample: $TIMEOUT seconds (expected latency: 6-11s)"
      echo ""

      # Check ClickHouse is available
      print_info "Connecting to ClickHouse..."
      CH_POD=$(get_pod_name "app=clickhouse")

      if [ -z "$CH_POD" ]; then
        print_fail "ClickHouse pod not found"
        exit 1
      fi

      if ! kubectl -n ${namespace} exec "$CH_POD" -- clickhouse-client --query "SELECT 1" >/dev/null 2>&1; then
        print_fail "ClickHouse not responding"
        exit 1
      fi
      print_pass "Connected to ClickHouse"

      # Get current max timestamp to track new logs (more robust than Count which resets on pod restart)
      CURRENT_TS=$(kubectl -n ${namespace} exec "$CH_POD" -- clickhouse-client --query "SELECT max(Timestamp) FROM otel_logs" 2>/dev/null || echo "")
      if [ -z "$CURRENT_TS" ] || [ "$CURRENT_TS" = "1970-01-01 00:00:00.000000000" ]; then
        print_warn "No logs yet in ClickHouse, waiting for initial logs..."
        sleep 10
        CURRENT_TS=$(kubectl -n ${namespace} exec "$CH_POD" -- clickhouse-client --query "SELECT max(Timestamp) FROM otel_logs" 2>/dev/null || echo "")
      fi

      print_info "Starting from timestamp: $CURRENT_TS"
      echo ""

      LATENCIES=()
      COLLECTED=0

      for ((i=1; i<=SAMPLES; i++)); do
        echo -e "''${BLUE}[Sample $i/$SAMPLES]''${NC}"

        # Record when we start waiting
        WAIT_START=$(date +%s.%N)

        # Wait for a new log to appear
        NEW_LOG=""
        ELAPSED=0
        while [ -z "$NEW_LOG" ] && [ "$(echo "$ELAPSED < $TIMEOUT" | bc -l)" = "1" ]; do
          NEW_LOG=$(kubectl -n ${namespace} exec "$CH_POD" -- clickhouse-client --query "
            SELECT
              Count,
              Timestamp,
              toFloat64(now64(3) - Timestamp) as age_seconds
            FROM otel_logs
            WHERE Timestamp > '$CURRENT_TS'
            ORDER BY Timestamp ASC
            LIMIT 1
          " 2>/dev/null || echo "")

          if [ -z "$NEW_LOG" ]; then
            sleep 0.5
            NOW=$(date +%s.%N)
            ELAPSED=$(echo "$NOW - $WAIT_START" | bc -l)
          fi
        done

        if [ -z "$NEW_LOG" ]; then
          print_warn "  Timeout waiting for new log"
          continue
        fi

        # Parse the result
        NEW_COUNT=$(echo "$NEW_LOG" | cut -f1)
        NEW_TS=$(echo "$NEW_LOG" | cut -f2)
        AGE=$(echo "$NEW_LOG" | cut -f3)

        # The age at detection time is our latency measurement
        LATENCIES+=("$AGE")
        COLLECTED=$((COLLECTED + 1))

        printf "  Log count: %s\n" "$NEW_COUNT"
        printf "  Timestamp: %s\n" "$NEW_TS"
        printf "  Latency:   %.3f seconds\n" "$AGE"
        echo ""

        # Update timestamp for next iteration
        CURRENT_TS=$NEW_TS
      done

      if [ "$COLLECTED" -eq 0 ]; then
        print_fail "No samples collected"
        exit 1
      fi

      # Calculate statistics
      print_header "Active Measurement Statistics"
      echo ""
      printf "  Samples collected: %d/%d\n" "$COLLECTED" "$SAMPLES"
      echo ""

      # Use awk for statistics
      STATS=$(printf '%s\n' "''${LATENCIES[@]}" | awk '
        BEGIN { min = 999999; max = 0; sum = 0; count = 0 }
        {
          if ($1 < min) min = $1
          if ($1 > max) max = $1
          sum += $1
          count++
        }
        END {
          if (count > 0) {
            printf "min=%.3f\n", min
            printf "max=%.3f\n", max
            printf "avg=%.3f\n", sum/count
          }
        }
      ')

      MIN_L=$(echo "$STATS" | grep "^min=" | cut -d= -f2)
      MAX_L=$(echo "$STATS" | grep "^max=" | cut -d= -f2)
      AVG_L=$(echo "$STATS" | grep "^avg=" | cut -d= -f2)

      printf "  %-20s %.3f seconds\n" "Minimum:" "$MIN_L"
      printf "  %-20s %.3f seconds\n" "Maximum:" "$MAX_L"
      printf "  %-20s %.3f seconds\n" "Average:" "$AVG_L"
      echo ""

      print_info "Active measurement provides more accurate latency by detecting"
      print_info "logs as soon as they appear in ClickHouse."
      echo ""
    '';
  };
}
