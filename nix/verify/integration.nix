# Deployment integration test scripts
#
# Self-contained tests for each deployment method:
# - test-docker-compose: Test Docker Compose deployment
# - test-minikube: Test standalone Minikube deployment
# - test-microvm: Test MicroVM with Minikube
# - test-all-deployments: Run all tests sequentially
{ pkgs, shellLib }:

let
  inherit (shellLib) mkVerifyScript;

  ports = import ../ports.nix;

  # Common verification logic shared across all deployments
  commonChecks = ''
    # Check if ClickHouse is responding (doesn't require data)
    check_clickhouse_ready() {
      local endpoint="$1"
      local result
      result=$(curl -s "$endpoint/?query=SELECT+1" 2>/dev/null)
      [ "$result" = "1" ]
    }

    check_hyperdx() {
      local endpoint="$1"
      curl -s "$endpoint/health" | jq -e '.data == "OK"' > /dev/null 2>&1
    }

    wait_for_logs() {
      local endpoint="$1"
      local timeout="$2"
      local start_count end_count

      start_count=$(curl -s "$endpoint/?query=SELECT+count()+FROM+otel_logs" 2>/dev/null || echo 0)
      sleep 10
      end_count=$(curl -s "$endpoint/?query=SELECT+count()+FROM+otel_logs" 2>/dev/null || echo 0)

      if [ "$end_count" -gt "$start_count" ]; then
        return 0
      fi
      return 1
    }

    # Verify all three logging methods are working (using Body to identify method)
    verify_all_methods() {
      local endpoint="$1"
      local all_ok=true

      # FluentBit logs contain "FluentBit" in body
      local count
      count=$(curl -s "$endpoint/" -d "SELECT count() FROM otel_logs WHERE Body LIKE '%FluentBit%' AND Timestamp > now() - INTERVAL 1 MINUTE" 2>/dev/null || echo 0)
      count=''${count:-0}
      if [ "$count" -gt 0 ]; then
        print_pass "FluentBit pipeline: $count logs in last minute"
        record_test pass
      else
        print_fail "FluentBit pipeline: no logs in last minute"
        record_test fail
        all_ok=false
      fi

      # OTLP logs contain "OTLP direct" in body
      count=$(curl -s "$endpoint/" -d "SELECT count() FROM otel_logs WHERE Body LIKE '%OTLP direct%' AND Timestamp > now() - INTERVAL 1 MINUTE" 2>/dev/null || echo 0)
      count=''${count:-0}
      if [ "$count" -gt 0 ]; then
        print_pass "OTLP direct pipeline: $count logs in last minute"
        record_test pass
      else
        print_fail "OTLP direct pipeline: no logs in last minute"
        record_test fail
        all_ok=false
      fi

      # Filelog logs contain "filelog receiver" in body
      count=$(curl -s "$endpoint/" -d "SELECT count() FROM otel_logs WHERE Body LIKE '%filelog receiver%' AND Timestamp > now() - INTERVAL 1 MINUTE" 2>/dev/null || echo 0)
      count=''${count:-0}
      if [ "$count" -gt 0 ]; then
        print_pass "Filelog pipeline: $count logs in last minute"
        record_test pass
      else
        print_fail "Filelog pipeline: no logs in last minute"
        record_test fail
        all_ok=false
      fi

      $all_ok
    }

    # Compare latency across all three methods (using Body to identify pipeline)
    compare_latency() {
      local endpoint="$1"

      print_info "Latency comparison by pipeline:"
      echo ""

      # Run latency query using Body content to identify method
      curl -s "$endpoint/" -d "
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
      " 2>/dev/null

      echo ""
    }
  '';

in
{
  test-docker-compose = mkVerifyScript {
    name = "test-docker-compose";
    runtimeInputs = with pkgs; [ docker curl jq coreutils ];
    text = ''
      ${commonChecks}

      print_header "Docker Compose Integration Test"
      init_test_counters

      # Ports from nix/ports.nix (compose section)
      CLICKHOUSE_URL="http://localhost:${toString ports.compose.clickhouseHttp}"
      HYPERDX_API="http://localhost:${toString ports.compose.hyperdxApi}"

      # Step 1: Start Docker Compose
      print_info "Starting Docker Compose stack..."
      nix run .#compose-up

      # Step 2: Wait for services (max 120s)
      print_info "Waiting for services to be ready..."
      for i in {1..24}; do
        if check_clickhouse_ready "$CLICKHOUSE_URL" && check_hyperdx "$HYPERDX_API"; then
          print_pass "Services ready"
          record_test pass
          break
        fi
        if [ "$i" -eq 24 ]; then
          print_fail "Services not ready after 120s"
          record_test fail
        fi
        sleep 5
      done

      # Step 3: Verify components
      print_info "Verifying components..."

      # Check containers
      for svc in clickhouse fluentbit loggen hyperdx mongodb; do
        if docker ps --format '{{.Names}}' | grep -q "otel-$svc"; then
          print_pass "$svc container running"
          record_test pass
        else
          print_fail "$svc container not running"
          record_test fail
        fi
      done

      # Step 4: Verify log flow
      print_info "Verifying log pipeline..."
      if wait_for_logs "$CLICKHOUSE_URL" 30; then
        print_pass "Logs flowing to ClickHouse"
        record_test pass
      else
        print_fail "No new logs in ClickHouse"
        record_test fail
      fi

      # Step 5: Verify fluentbit logging method (Docker Compose only has FluentBit, not OTel Collector)
      # Use Body content to identify FluentBit logs
      print_info "Verifying FluentBit logging pipeline..."
      sleep 30  # Wait for logs to accumulate
      count=$(curl -s "$CLICKHOUSE_URL/" -d "SELECT count() FROM otel_logs WHERE Body LIKE '%FluentBit%' AND Timestamp > now() - INTERVAL 1 MINUTE" 2>/dev/null || echo 0)
      count=''${count:-0}
      if [ "$count" -gt 0 ]; then
        print_pass "FluentBit pipeline: $count logs in last minute"
        record_test pass
      else
        # Try without Body filter as fallback
        total=$(curl -s "$CLICKHOUSE_URL/" -d "SELECT count() FROM otel_logs WHERE Timestamp > now() - INTERVAL 1 MINUTE" 2>/dev/null || echo 0)
        if [ "$total" -gt 0 ]; then
          print_pass "Logs flowing: $total logs in last minute"
          record_test pass
        else
          print_fail "FluentBit pipeline: no logs in last minute"
          record_test fail
        fi
      fi

      # Step 7: Cleanup
      print_info "Stopping Docker Compose..."
      nix run .#compose-down

      print_test_summary "Docker Compose Integration Test"
    '';
  };

  test-minikube = mkVerifyScript {
    name = "test-minikube";
    runtimeInputs = with pkgs; [ minikube kubectl docker curl jq coreutils ];
    text = ''
      ${commonChecks}

      print_header "Minikube Integration Test"
      init_test_counters

      NAMESPACE="otel-demo"

      # Step 1: Start Minikube
      print_info "Starting Minikube..."
      minikube delete 2>/dev/null || true
      minikube start --driver=docker --memory=4g --cpus=2
      print_pass "Minikube started"
      record_test pass

      # Step 2: Load images
      print_info "Loading container images..."
      for img in loggen fluentbit clickhouse mongodb hyperdx; do
        nix build ".#''${img}-image" -o "/tmp/''${img}-image"
        minikube image load "/tmp/''${img}-image"
      done
      print_pass "Images loaded"
      record_test pass

      # Step 3: Deploy manifests
      print_info "Deploying K8s manifests..."
      kubectl create namespace $NAMESPACE 2>/dev/null || true
      kubectl apply -f k8s/ -R 2>/dev/null || true

      # Step 4: Wait for pods
      print_info "Waiting for pods..."
      if kubectl wait --for=condition=ready pod -l app=clickhouse -n $NAMESPACE --timeout=120s; then
        print_pass "ClickHouse ready"
        record_test pass
      else
        print_fail "ClickHouse not ready"
        record_test fail
      fi

      if kubectl wait --for=condition=ready pod -l app=loggen -n $NAMESPACE --timeout=60s; then
        print_pass "Loggen ready"
        record_test pass
      else
        print_fail "Loggen not ready"
        record_test fail
      fi

      if kubectl wait --for=condition=ready pod -l app=hyperdx -n $NAMESPACE --timeout=120s; then
        print_pass "HyperDX ready"
        record_test pass
      else
        print_fail "HyperDX not ready"
        record_test fail
      fi

      # Step 5: Verify log flow
      print_info "Verifying log pipeline..."
      sleep 15  # Let some logs accumulate
      LOG_COUNT=$(kubectl exec -n $NAMESPACE clickhouse-0 -- \
        clickhouse-client --query "SELECT count() FROM otel_logs" 2>/dev/null || echo 0)
      if [ "$LOG_COUNT" -gt 0 ]; then
        print_pass "Logs in ClickHouse: $LOG_COUNT"
        record_test pass
      else
        print_fail "No logs in ClickHouse"
        record_test fail
      fi

      # Step 6: Verify all three logging methods (using Body content to identify pipeline)
      print_info "Verifying all three logging pipelines..."
      sleep 30  # Wait for all methods to produce logs

      # FluentBit logs contain "FluentBit" in body
      count=$(kubectl exec -n $NAMESPACE clickhouse-0 -- \
        clickhouse-client --query "SELECT count() FROM otel_logs WHERE Body LIKE '%FluentBit%' AND Timestamp > now() - INTERVAL 1 MINUTE" 2>/dev/null || echo 0)
      if [ "$count" -gt 0 ]; then
        print_pass "FluentBit pipeline: $count logs in last minute"
        record_test pass
      else
        print_fail "FluentBit pipeline: no logs in last minute"
        record_test fail
      fi

      # OTLP logs contain "OTLP direct" in body
      count=$(kubectl exec -n $NAMESPACE clickhouse-0 -- \
        clickhouse-client --query "SELECT count() FROM otel_logs WHERE Body LIKE '%OTLP direct%' AND Timestamp > now() - INTERVAL 1 MINUTE" 2>/dev/null || echo 0)
      if [ "$count" -gt 0 ]; then
        print_pass "OTLP direct pipeline: $count logs in last minute"
        record_test pass
      else
        print_fail "OTLP direct pipeline: no logs in last minute"
        record_test fail
      fi

      # Filelog logs contain "filelog receiver" in body
      count=$(kubectl exec -n $NAMESPACE clickhouse-0 -- \
        clickhouse-client --query "SELECT count() FROM otel_logs WHERE Body LIKE '%filelog receiver%' AND Timestamp > now() - INTERVAL 1 MINUTE" 2>/dev/null || echo 0)
      if [ "$count" -gt 0 ]; then
        print_pass "Filelog pipeline: $count logs in last minute"
        record_test pass
      else
        print_fail "Filelog pipeline: no logs in last minute"
        record_test fail
      fi

      # Step 7: Show latency comparison (using Body content to identify pipeline)
      print_info "Latency comparison by pipeline:"
      kubectl exec -n $NAMESPACE clickhouse-0 -- clickhouse-client --query "
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

      # Step 9: Cleanup
      print_info "Cleaning up Minikube..."
      minikube delete

      print_test_summary "Minikube Integration Test"
    '';
  };

  test-microvm = mkVerifyScript {
    name = "test-microvm";
    runtimeInputs = with pkgs; [ sshpass curl jq coreutils procps netcat ];
    text = ''
      ${commonChecks}

      print_header "MicroVM Integration Test"
      init_test_counters

      SSH_PORT=${toString ports.hostForwards.ssh}
      SSH_PASS="demo"
      SSH_CMD="sshpass -p $SSH_PASS ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p $SSH_PORT root@localhost"

      # Step 1: Clean up any existing MicroVM and check ports
      print_info "Cleaning up existing MicroVM..."
      pkill -9 -f "microvm@otel-demo" 2>/dev/null || true
      rm -f var.img control.sock
      sleep 2

      # Check if SSH port is already in use (indicates leftover VM)
      if nc -z localhost $SSH_PORT 2>/dev/null; then
        print_fail "Port $SSH_PORT already in use - is another MicroVM running?"
        print_info "Run: pkill -9 -f 'microvm@otel-demo' to clean up"
        exit 1
      fi

      # Step 2: Build and start MicroVM
      print_info "Building MicroVM (this may take a while on first run)..."
      nix build .#nixosConfigurations.microvm-minikube.config.microvm.declaredRunner --no-link

      print_info "Starting MicroVM..."
      VM_LOG="/tmp/microvm-test-$$.log"
      nix run .#microvm-minikube > "$VM_LOG" 2>&1 &
      VM_PID=$!
      print_info "MicroVM PID: $VM_PID (logs: $VM_LOG)"

      # Step 3: Wait for SSH (VM boot can take a while)
      print_info "Waiting for MicroVM SSH (up to 5 minutes)..."
      SSH_READY=false
      for i in {1..60}; do
        if nc -zv localhost $SSH_PORT 2>/dev/null; then
          print_pass "SSH accessible"
          record_test pass
          SSH_READY=true
          break
        fi
        if [ "$i" -eq 60 ]; then
          print_fail "SSH not accessible after 5 minutes"
          record_test fail
        fi
        sleep 5
      done

      # Step 4: Wait for Minikube inside VM (can take several minutes)
      if [ "$SSH_READY" != "true" ]; then
        print_fail "Cannot check Minikube - SSH not available"
        record_test fail
        MINIKUBE_READY=false
      else
        print_info "Waiting for Minikube inside VM (up to 10 minutes)..."
        MINIKUBE_READY=false
        for i in {1..60}; do
          if $SSH_CMD 'minikube status' 2>/dev/null | grep -q "Running"; then
            print_pass "Minikube running inside VM"
            record_test pass
            MINIKUBE_READY=true
            break
          fi
          if [ "$i" -eq 60 ]; then
            print_fail "Minikube not ready inside VM after 10 minutes"
            record_test fail
          fi
          sleep 10
        done
      fi

      # Step 5: Wait for pods to be ready
      if [ "''${MINIKUBE_READY:-false}" != "true" ]; then
        print_fail "Cannot check pods - Minikube not available"
        record_test fail
        PODS_READY=false
      else
        print_info "Waiting for pods inside MicroVM (up to 5 minutes)..."
        PODS_READY=false
        POD_COUNT=0
        for i in {1..30}; do
          POD_COUNT=$($SSH_CMD 'kubectl get pods -n otel-demo --no-headers 2>/dev/null | grep -c Running || echo 0' 2>/dev/null | tail -1 | tr -d '[:space:]')
          POD_COUNT=''${POD_COUNT:-0}
          if [ "$POD_COUNT" -ge 4 ]; then
            print_pass "Pods running: $POD_COUNT"
            record_test pass
            PODS_READY=true
            break
          fi
          if [ "$i" -eq 30 ]; then
            print_fail "Not enough pods running after 5 minutes: $POD_COUNT"
            record_test fail
          fi
          sleep 10
        done
      fi

      # Step 6: Verify log flow (wait for logs to accumulate)
      if [ "''${PODS_READY:-false}" != "true" ]; then
        print_fail "Cannot check logs - pods not ready"
        record_test fail
      else
        print_info "Waiting for logs in ClickHouse (up to 2 minutes)..."
        LOG_COUNT=0
        for i in {1..12}; do
          LOG_COUNT=$($SSH_CMD 'kubectl exec -n otel-demo clickhouse-0 -- clickhouse-client --query "SELECT count() FROM otel_logs" 2>/dev/null || echo 0' 2>/dev/null | tail -1 | tr -d '[:space:]')
          LOG_COUNT=''${LOG_COUNT:-0}
          if [ "$LOG_COUNT" -gt 0 ]; then
            print_pass "Logs in ClickHouse: $LOG_COUNT"
            record_test pass
            break
          fi
          if [ "$i" -eq 12 ]; then
            print_fail "No logs in ClickHouse after 2 minutes"
            record_test fail
          fi
          sleep 10
        done
      fi

      # Step 7: Cleanup
      print_info "Stopping MicroVM..."
      if [ -n "''${VM_PID:-}" ] && kill -0 "$VM_PID" 2>/dev/null; then
        kill "$VM_PID" 2>/dev/null || true
      fi
      pkill -f "microvm@otel-demo" 2>/dev/null || true

      # Show last few lines of VM log if test failed
      if [ -f "''${VM_LOG:-/dev/null}" ]; then
        if [ "''${SSH_READY:-false}" != "true" ]; then
          print_info "Last 20 lines of VM log:"
          tail -20 "$VM_LOG" 2>/dev/null || true
        fi
        rm -f "$VM_LOG"
      fi

      print_test_summary "MicroVM Integration Test"
    '';
  };

  # test-all-deployments uses writeShellApplication directly since it doesn't
  # need the test counter functions that mkVerifyScript includes
  test-all-deployments = pkgs.writeShellApplication {
    name = "test-all-deployments";
    runtimeInputs = with pkgs; [ coreutils ];
    text = ''
      # Colors
      RED='\033[0;31m'
      GREEN='\033[0;32m'
      BLUE='\033[0;34m'
      NC='\033[0m'

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

      print_info() {
        echo -e "''${BLUE}[INFO]''${NC} $1"
      }

      print_header "Running All Deployment Integration Tests"

      TOTAL_PASSED=0
      TOTAL_FAILED=0

      run_test() {
        local test_name="$1"
        print_info "========================================"
        print_info "Running: $test_name"
        print_info "========================================"

        if nix run ".#$test_name"; then
          echo ""
          print_pass "$test_name completed successfully"
          TOTAL_PASSED=$((TOTAL_PASSED + 1))
        else
          echo ""
          print_fail "$test_name failed"
          TOTAL_FAILED=$((TOTAL_FAILED + 1))
        fi
        echo ""
      }

      # Run tests sequentially
      run_test "test-docker-compose"
      run_test "test-minikube"
      run_test "test-microvm"

      # Final summary
      print_header "All Deployment Tests Summary"
      echo ""
      echo "  Passed: $TOTAL_PASSED/3"
      echo "  Failed: $TOTAL_FAILED/3"
      echo ""

      if [ "$TOTAL_FAILED" -gt 0 ]; then
        print_fail "Some tests failed"
        exit 1
      else
        print_pass "All tests passed!"
        exit 0
      fi
    '';
  };
}
