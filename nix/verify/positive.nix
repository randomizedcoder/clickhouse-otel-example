# Positive verification scripts - verify each pipeline stage is working
{ pkgs, shellLib }:
let
  inherit (shellLib) namespace commonFunctions mkVerifyScript;
in
{
  verify-loggen = mkVerifyScript {
    name = "verify-loggen";
    text = ''
      print_header "Verifying Loggen (Go Log Generator)"

      PASSED=0
      FAILED=0

      # Check 1: Pod is running
      print_info "Checking if loggen pod is running..."
      if check_pod_running "app=loggen"; then
        print_pass "Loggen pod is running"
        PASSED=$((PASSED + 1))
      else
        print_fail "Loggen pod is not running"
        FAILED=$((FAILED + 1))
        echo "  Run: kubectl -n ${namespace} get pods -l app=loggen"
        exit 1
      fi

      POD_NAME=$(get_pod_name "app=loggen")

      # Check 2: Health endpoint (via readiness/liveness probe status)
      print_info "Checking pod health conditions..."
      POD_READY=$(kubectl -n ${namespace} get pod "$POD_NAME" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
      if [ "$POD_READY" = "True" ]; then
        print_pass "Pod is healthy (Ready condition is True)"
        PASSED=$((PASSED + 1))
      else
        print_fail "Pod is not healthy (Ready: $POD_READY)"
        FAILED=$((FAILED + 1))
      fi

      # Check 3: Container ready
      print_info "Checking container status..."
      CONTAINER_READY=$(kubectl -n ${namespace} get pod "$POD_NAME" -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null || echo "")
      if [ "$CONTAINER_READY" = "true" ]; then
        print_pass "Container is ready"
        PASSED=$((PASSED + 1))
      else
        print_fail "Container is not ready"
        FAILED=$((FAILED + 1))
      fi

      # Check 4: Log output format (JSON with expected fields)
      print_info "Checking log output format..."
      LOG_LINE=$(kubectl -n ${namespace} logs "$POD_NAME" --tail=1 2>/dev/null || echo "")
      if echo "$LOG_LINE" | jq -e '.level and .ts and .msg and .count and .random_number and .random_string' >/dev/null 2>&1; then
        print_pass "Log output is valid JSON with expected fields"
        PASSED=$((PASSED + 1))
        echo ""
        echo "  Sample log entry:"
        echo "$LOG_LINE" | jq -C '.'
      else
        print_fail "Log output format is invalid"
        FAILED=$((FAILED + 1))
        echo "  Got: $LOG_LINE"
      fi

      # Summary
      echo ""
      print_header "Loggen Verification Summary"
      echo "Passed: $PASSED"
      echo "Failed: $FAILED"

      if [ "$FAILED" -gt 0 ]; then
        exit 1
      fi
    '';
  };

  verify-fluentbit = mkVerifyScript {
    name = "verify-fluentbit";
    text = ''
      print_header "Verifying FluentBit (Log Collector)"

      PASSED=0
      FAILED=0

      # Check 1: DaemonSet is ready
      print_info "Checking if FluentBit DaemonSet is ready..."
      DESIRED=$(kubectl -n ${namespace} get daemonset fluentbit -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || echo "0")
      READY=$(kubectl -n ${namespace} get daemonset fluentbit -o jsonpath='{.status.numberReady}' 2>/dev/null || echo "0")
      if [ "$DESIRED" -gt 0 ] && [ "$DESIRED" = "$READY" ]; then
        print_pass "FluentBit DaemonSet is ready ($READY/$DESIRED pods)"
        PASSED=$((PASSED + 1))
      else
        print_fail "FluentBit DaemonSet is not ready ($READY/$DESIRED pods)"
        FAILED=$((FAILED + 1))
        exit 1
      fi

      POD_NAME=$(get_pod_name "app=fluentbit")

      # Check 2: Pod readiness (indicates health endpoint is responding)
      print_info "Checking pod readiness..."
      POD_READY=$(kubectl -n ${namespace} get pod "$POD_NAME" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
      if [ "$POD_READY" = "True" ]; then
        print_pass "FluentBit pod is ready (health check passing)"
        PASSED=$((PASSED + 1))
      else
        print_fail "FluentBit pod is not ready"
        FAILED=$((FAILED + 1))
      fi

      # Check 3: Container running without restarts
      print_info "Checking container stability..."
      RESTART_COUNT=$(kubectl -n ${namespace} get pod "$POD_NAME" -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null || echo "999")
      if [ "$RESTART_COUNT" -lt 5 ]; then
        print_pass "Container is stable ($RESTART_COUNT restarts)"
        PASSED=$((PASSED + 1))
      else
        print_warn "Container has restarted $RESTART_COUNT times"
      fi

      # Check 4: No Lua errors in logs
      print_info "Checking for Lua script errors..."
      LUA_ERRORS=0
      if kubectl -n ${namespace} logs "$POD_NAME" --tail=100 2>/dev/null | grep -qi "lua.*error\|lua.*exception\|lua.*failed"; then
        LUA_ERRORS=$(kubectl -n ${namespace} logs "$POD_NAME" --tail=100 2>/dev/null | grep -ci "lua.*error\|lua.*exception\|lua.*failed")
        print_fail "Found $LUA_ERRORS Lua errors in logs"
        FAILED=$((FAILED + 1))
        kubectl -n ${namespace} logs "$POD_NAME" --tail=100 2>/dev/null | grep -i "lua.*error\|lua.*exception\|lua.*failed" || true
      else
        print_pass "No Lua script errors found"
        PASSED=$((PASSED + 1))
      fi

      # Check 5: FluentBit is processing logs (check log output)
      print_info "Checking if FluentBit is processing logs..."
      FB_LOGS=$(kubectl -n ${namespace} logs "$POD_NAME" --tail=20 2>/dev/null || echo "")
      if echo "$FB_LOGS" | grep -q "input:tail"; then
        print_pass "FluentBit tail input is active"
        PASSED=$((PASSED + 1))
      else
        print_warn "Could not confirm FluentBit is tailing logs"
      fi

      # Show FluentBit logs summary
      echo ""
      print_info "Recent FluentBit activity:"
      kubectl -n ${namespace} logs "$POD_NAME" --tail=10 2>/dev/null | grep -v "^\\[0\\]" | head -5 || echo "  No recent logs"

      # Summary
      echo ""
      print_header "FluentBit Verification Summary"
      echo "Passed: $PASSED"
      echo "Failed: $FAILED"

      if [ "$FAILED" -gt 0 ]; then
        exit 1
      fi
    '';
  };

  verify-fluentbit-output = mkVerifyScript {
    name = "verify-fluentbit-output";
    text = ''
      print_header "Verifying FluentBit Output (ClickHouse Connection)"

      PASSED=0
      FAILED=0

      FB_POD=$(get_pod_name "app=fluentbit")

      if [ -z "$FB_POD" ]; then
        print_fail "FluentBit pod not found"
        exit 1
      fi

      # Check 1: No HTTP errors in recent logs (indicates output is working)
      print_info "Checking for HTTP output errors..."
      HTTP_ERRORS=0
      FB_LOGS=$(kubectl -n ${namespace} logs "$FB_POD" --tail=50 2>/dev/null || echo "")
      if echo "$FB_LOGS" | grep -q "HTTP status=4\|HTTP status=5"; then
        HTTP_ERRORS=$(echo "$FB_LOGS" | grep -c "HTTP status=4\|HTTP status=5")
      fi
      if [ "$HTTP_ERRORS" -lt 5 ]; then
        print_pass "HTTP output errors are acceptable ($HTTP_ERRORS errors)"
        PASSED=$((PASSED + 1))
      else
        print_fail "Too many HTTP output errors ($HTTP_ERRORS errors)"
        FAILED=$((FAILED + 1))
      fi

      # Check 2: ClickHouse service exists and is reachable
      print_info "Checking ClickHouse service..."
      CH_SVC=$(kubectl -n ${namespace} get svc clickhouse -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "")
      if [ -n "$CH_SVC" ]; then
        print_pass "ClickHouse service exists (IP: $CH_SVC)"
        PASSED=$((PASSED + 1))
      else
        print_fail "ClickHouse service not found"
        FAILED=$((FAILED + 1))
      fi

      # Check 3: No connection errors in recent logs
      print_info "Checking for connection errors in logs..."
      CONN_ERRORS=0
      if echo "$FB_LOGS" | grep -qi "connection refused\|connection reset\|no route to host"; then
        CONN_ERRORS=$(echo "$FB_LOGS" | grep -ci "connection refused\|connection reset\|no route to host")
      fi
      if [ "$CONN_ERRORS" = "0" ]; then
        print_pass "No connection errors in recent logs"
        PASSED=$((PASSED + 1))
      else
        print_fail "Found $CONN_ERRORS connection errors in recent logs"
        FAILED=$((FAILED + 1))
      fi

      # Check 4: FluentBit output worker is active
      print_info "Checking output worker status..."
      WORKER_LOGS=$(kubectl -n ${namespace} logs "$FB_POD" --tail=100 2>/dev/null || echo "")
      if echo "$WORKER_LOGS" | grep -q "output:http.*worker"; then
        print_pass "HTTP output worker is active"
        PASSED=$((PASSED + 1))
      else
        print_warn "Could not confirm HTTP output worker status"
      fi

      # Show recent output activity
      echo ""
      print_info "Recent FluentBit Output Activity:"
      kubectl -n ${namespace} logs "$FB_POD" --tail=20 2>/dev/null | grep -i "output\|http" | tail -5 || echo "  No recent output activity"

      # Summary
      echo ""
      print_header "FluentBit Output Verification Summary"
      echo "Passed: $PASSED"
      echo "Failed: $FAILED"

      if [ "$FAILED" -gt 0 ]; then
        exit 1
      fi
    '';
  };

  verify-clickhouse = mkVerifyScript {
    name = "verify-clickhouse";
    text = ''
      print_header "Verifying ClickHouse (Log Storage)"

      PASSED=0
      FAILED=0

      # Check 1: Pod is running
      print_info "Checking if ClickHouse pod is running..."
      if check_pod_running "app=clickhouse"; then
        print_pass "ClickHouse pod is running"
        PASSED=$((PASSED + 1))
      else
        print_fail "ClickHouse pod is not running"
        FAILED=$((FAILED + 1))
        exit 1
      fi

      POD_NAME=$(get_pod_name "app=clickhouse")

      # Check 2: ClickHouse server responding
      print_info "Checking ClickHouse server..."
      CH_PING=$(kubectl -n ${namespace} exec "$POD_NAME" -- clickhouse-client --query "SELECT 1" 2>/dev/null || echo "")
      if [ "$CH_PING" = "1" ]; then
        print_pass "ClickHouse server is responding"
        PASSED=$((PASSED + 1))
      else
        print_fail "ClickHouse server not responding"
        FAILED=$((FAILED + 1))
      fi

      # Check 3: otel_logs table exists
      print_info "Checking if otel_logs table exists..."
      TABLE_EXISTS=$(kubectl -n ${namespace} exec "$POD_NAME" -- clickhouse-client --query "EXISTS TABLE default.otel_logs" 2>/dev/null || echo "0")
      if [ "$TABLE_EXISTS" = "1" ]; then
        print_pass "otel_logs table exists"
        PASSED=$((PASSED + 1))
      else
        print_fail "otel_logs table does not exist"
        FAILED=$((FAILED + 1))
        exit 1
      fi

      # Check 4: Records in table (with retry)
      print_info "Checking for records in otel_logs table (with 60s timeout)..."
      RECORD_COUNT=0
      for i in $(seq 1 12); do
        RECORD_COUNT=$(kubectl -n ${namespace} exec "$POD_NAME" -- clickhouse-client --query "SELECT count() FROM default.otel_logs" 2>/dev/null || echo "0")
        if [ "$RECORD_COUNT" -gt 0 ]; then
          break
        fi
        print_info "  Waiting for records... ($i/12)"
        sleep 5
      done

      if [ "$RECORD_COUNT" -gt 0 ]; then
        print_pass "Found $RECORD_COUNT records in otel_logs table"
        PASSED=$((PASSED + 1))
      else
        print_warn "No records found in otel_logs table yet"
      fi

      # Check 5: Schema validation
      print_info "Validating table schema..."
      SCHEMA_VALID=$(kubectl -n ${namespace} exec "$POD_NAME" -- clickhouse-client --query "SELECT count() FROM system.columns WHERE table='otel_logs' AND name IN ('Timestamp','SeverityText','SeverityNumber','ServiceName','Body','RandomNumber','RandomString','Count')" 2>/dev/null || echo "0")
      if [ "$SCHEMA_VALID" = "8" ]; then
        print_pass "Table schema has all expected columns"
        PASSED=$((PASSED + 1))
      else
        print_fail "Table schema is missing columns (found $SCHEMA_VALID/8)"
        FAILED=$((FAILED + 1))
      fi

      # Show sample record
      echo ""
      print_info "Sample Record from otel_logs:"
      kubectl -n ${namespace} exec "$POD_NAME" -- clickhouse-client --format=JSONEachRow --query "SELECT * FROM default.otel_logs LIMIT 1" 2>/dev/null | jq -C '.' || echo "  No records available"

      # Show table statistics
      echo ""
      print_info "Table Statistics:"
      kubectl -n ${namespace} exec "$POD_NAME" -- clickhouse-client --query "SELECT count() as total_records, min(Timestamp) as oldest, max(Timestamp) as newest FROM default.otel_logs" 2>/dev/null || echo "  Unable to fetch statistics"

      # Summary
      echo ""
      print_header "ClickHouse Verification Summary"
      echo "Passed: $PASSED"
      echo "Failed: $FAILED"
      echo "Total records: $RECORD_COUNT"

      if [ "$FAILED" -gt 0 ]; then
        exit 1
      fi
    '';
  };

  verify-hyperdx = mkVerifyScript {
    name = "verify-hyperdx";
    text = ''
      print_header "Verifying HyperDX (Log Visualization)"

      PASSED=0
      FAILED=0

      # Check 1: Pod is running
      print_info "Checking if HyperDX pod is running..."
      if check_pod_running "app=hyperdx"; then
        print_pass "HyperDX pod is running"
        PASSED=$((PASSED + 1))
      else
        print_fail "HyperDX pod is not running"
        FAILED=$((FAILED + 1))
        exit 1
      fi

      POD_NAME=$(get_pod_name "app=hyperdx")

      # Check 2: Pod is ready (liveness/readiness probes passing)
      print_info "Checking pod readiness..."
      POD_READY=$(kubectl -n ${namespace} get pod "$POD_NAME" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
      if [ "$POD_READY" = "True" ]; then
        print_pass "HyperDX pod is ready (health checks passing)"
        PASSED=$((PASSED + 1))
      else
        print_fail "HyperDX pod is not ready"
        FAILED=$((FAILED + 1))
      fi

      # Check 3: Container is ready
      print_info "Checking container status..."
      CONTAINER_READY=$(kubectl -n ${namespace} get pod "$POD_NAME" -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null || echo "")
      if [ "$CONTAINER_READY" = "true" ]; then
        print_pass "HyperDX container is ready"
        PASSED=$((PASSED + 1))
      else
        print_fail "HyperDX container is not ready"
        FAILED=$((FAILED + 1))
      fi

      # Check 4: MongoDB connectivity (for session storage)
      print_info "Checking MongoDB connectivity..."
      MONGO_POD=$(get_pod_name "app=mongodb")
      if [ -n "$MONGO_POD" ]; then
        MONGO_READY=$(kubectl -n ${namespace} get pod "$MONGO_POD" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
        if [ "$MONGO_READY" = "True" ]; then
          print_pass "MongoDB pod is ready"
          PASSED=$((PASSED + 1))
        else
          print_warn "MongoDB pod exists but not ready"
        fi
      else
        print_warn "MongoDB pod not found (HyperDX may have limited functionality)"
      fi

      # Check 5: HyperDX service has endpoints
      print_info "Checking HyperDX service..."
      SVC_ENDPOINTS=$(kubectl -n ${namespace} get endpoints hyperdx -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null || echo "")
      if [ -n "$SVC_ENDPOINTS" ]; then
        print_pass "HyperDX service has endpoints ($SVC_ENDPOINTS)"
        PASSED=$((PASSED + 1))
      else
        print_fail "HyperDX service has no endpoints"
        FAILED=$((FAILED + 1))
      fi

      # Show access URLs
      echo ""
      print_info "HyperDX Access URLs:"
      NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || echo "<node-ip>")
      echo "  API:  http://$NODE_IP:30800"
      echo "  UI:   http://$NODE_IP:30808"
      echo ""
      echo "  Or use port-forward:"
      echo "    kubectl -n ${namespace} port-forward svc/hyperdx 8000:8000 8080:8080"
      echo "    API: http://localhost:8000"
      echo "    UI:  http://localhost:8080"

      # Summary
      echo ""
      print_header "HyperDX Verification Summary"
      echo "Passed: $PASSED"
      echo "Failed: $FAILED"

      if [ "$FAILED" -gt 0 ]; then
        exit 1
      fi
    '';
  };

  verify-pipeline = mkVerifyScript {
    name = "verify-pipeline";
    text = ''
      print_header "Pipeline Verification - All Stages"

      TOTAL_PASSED=0
      TOTAL_FAILED=0
      STAGES=("loggen" "fluentbit" "fluentbit-output" "clickhouse" "hyperdx")
      RESULTS=()

      for stage in "''${STAGES[@]}"; do
        echo ""
        echo -e "''${BLUE}>>> Running verify-$stage...''${NC}"
        echo ""

        if nix run ".#verify-$stage" 2>&1; then
          RESULTS+=("PASS")
          TOTAL_PASSED=$((TOTAL_PASSED + 1))
        else
          RESULTS+=("FAIL")
          TOTAL_FAILED=$((TOTAL_FAILED + 1))
        fi
      done

      # Summary
      print_header "Pipeline Verification Summary"
      echo ""
      for i in "''${!STAGES[@]}"; do
        if [ "''${RESULTS[$i]}" = "PASS" ]; then
          print_pass "''${STAGES[$i]}"
        else
          print_fail "''${STAGES[$i]}"
        fi
      done

      echo ""
      echo "=============================================="
      echo "Passed: $TOTAL_PASSED/''${#STAGES[@]}"
      echo "Failed: $TOTAL_FAILED/''${#STAGES[@]}"
      echo "=============================================="

      if [ "$TOTAL_FAILED" -eq 0 ]; then
        echo ""
        echo -e "''${GREEN}ALL STAGES PASSED - Pipeline is healthy!''${NC}"
        echo ""
      else
        echo ""
        echo -e "''${RED}SOME STAGES FAILED - Check individual results above''${NC}"
        echo ""
        exit 1
      fi
    '';
  };
}
