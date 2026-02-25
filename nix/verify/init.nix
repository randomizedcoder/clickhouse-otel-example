# Initialization scripts for the pipeline
{ pkgs, shellLib }:
let
  inherit (shellLib) namespace commonFunctions mkVerifyScript;
in
{
  init-clickhouse = mkVerifyScript {
    name = "init-clickhouse";
    runtimeInputs = [ pkgs.kubectl ];
    text = ''
      print_header "Initializing ClickHouse Schema"

      # Wait for ClickHouse pod to be ready
      print_info "Waiting for ClickHouse pod to be ready..."
      if ! kubectl -n ${namespace} wait --for=condition=ready pod -l app=clickhouse --timeout=120s 2>/dev/null; then
        print_fail "ClickHouse pod not ready"
        exit 1
      fi

      POD_NAME=$(get_pod_name "app=clickhouse")
      print_pass "ClickHouse pod is ready: $POD_NAME"

      # Wait for ClickHouse server to accept connections
      print_info "Waiting for ClickHouse server to accept connections..."
      for i in $(seq 1 30); do
        if kubectl -n ${namespace} exec "$POD_NAME" -- clickhouse-client --query "SELECT 1" 2>/dev/null; then
          print_pass "ClickHouse server is accepting connections"
          break
        fi
        if [ "$i" -eq 30 ]; then
          print_fail "ClickHouse server not responding after 30 attempts"
          exit 1
        fi
        echo "  Attempt $i/30 - waiting..."
        sleep 2
      done

      # Check if table already exists
      print_info "Checking if otel_logs table already exists..."
      TABLE_EXISTS=$(kubectl -n ${namespace} exec "$POD_NAME" -- clickhouse-client --query "EXISTS TABLE default.otel_logs" 2>/dev/null || echo "0")
      if [ "$TABLE_EXISTS" = "1" ]; then
        print_warn "otel_logs table already exists - skipping initialization"
        echo "  Use 'nix run .#break-clickhouse-table' then 'nix run .#init-clickhouse' to recreate"
        exit 0
      fi

      # Get init SQL from ConfigMap or local file
      print_info "Loading init.sql..."
      INIT_SQL=$(kubectl -n ${namespace} get configmap clickhouse-init -o jsonpath='{.data.init\.sql}' 2>/dev/null || echo "")

      if [ -z "$INIT_SQL" ]; then
        print_warn "ConfigMap not found, trying local file..."
        if [ -f k8s/clickhouse/init.sql ]; then
          INIT_SQL=$(cat k8s/clickhouse/init.sql)
        else
          print_fail "Could not find init.sql in ConfigMap or local file"
          exit 1
        fi
      fi

      # Execute init SQL
      print_info "Executing init.sql..."
      if echo "$INIT_SQL" | kubectl -n ${namespace} exec -i "$POD_NAME" -- clickhouse-client --multiquery; then
        print_pass "Schema initialization complete"
      else
        print_fail "Schema initialization failed"
        exit 1
      fi

      # Verify table was created
      print_info "Verifying table creation..."
      TABLES=$(kubectl -n ${namespace} exec "$POD_NAME" -- clickhouse-client --query "SHOW TABLES FROM default" 2>/dev/null || echo "")
      echo "  Tables in default database:"
      while IFS= read -r line; do
        echo "    $line"
      done <<< "$TABLES"

      if echo "$TABLES" | grep -q "otel_logs"; then
        print_pass "otel_logs table created successfully"
      else
        print_fail "otel_logs table not found after initialization"
        exit 1
      fi

      print_header "ClickHouse Initialization Complete"
    '';
  };
}
