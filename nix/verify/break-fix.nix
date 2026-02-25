# Break/fix scripts for failure injection testing
{ pkgs, shellLib }:
let
  inherit (pkgs) lib;
  inherit (shellLib) namespace commonFunctions;

  # Define break/fix pairs declaratively
  breakFixPairs = {
    loggen = {
      description = "Loggen";
      breakAction = "kubectl -n ${namespace} scale deployment/loggen --replicas=0";
      fixAction = "kubectl -n ${namespace} scale deployment/loggen --replicas=1";
      waitAction = "kubectl -n ${namespace} wait --for=condition=ready pod -l app=loggen --timeout=60s";
      verifyCmd = "nix run .#verify-loggen";
      fixCmd = "nix run .#fix-loggen";
    };

    fluentbit = {
      description = "FluentBit";
      breakAction = ''
        kubectl -n ${namespace} patch daemonset/fluentbit \
          -p '{"spec":{"template":{"spec":{"containers":[{"name":"fluentbit","image":"invalid:broken"}]}}}}'
      '';
      fixAction = "kubectl -n ${namespace} rollout undo daemonset/fluentbit";
      waitAction = "kubectl -n ${namespace} rollout status daemonset/fluentbit --timeout=120s";
      verifyCmd = "nix run .#verify-fluentbit";
      fixCmd = "nix run .#fix-fluentbit";
    };

    fluentbit-lua = {
      description = "FluentBit Lua Script";
      breakAction = ''
        kubectl -n ${namespace} patch configmap/fluentbit-config \
          --type=merge -p '{"data":{"transform.lua":"syntax error here!!!"}}'

        print_info "Restarting FluentBit DaemonSet..."
        kubectl -n ${namespace} rollout restart daemonset/fluentbit
      '';
      fixAction = ''
        kubectl apply -k k8s/fluentbit/ || kubectl apply -f k8s/fluentbit/

        print_info "Restarting FluentBit DaemonSet..."
        kubectl -n ${namespace} rollout restart daemonset/fluentbit
      '';
      waitAction = "kubectl -n ${namespace} rollout status daemonset/fluentbit --timeout=120s";
      verifyCmd = "nix run .#verify-fluentbit";
      fixCmd = "nix run .#fix-fluentbit-lua";
    };

    fluentbit-output = {
      description = "FluentBit Output";
      breakAction = ''
        kubectl -n ${namespace} patch configmap/fluentbit-config \
          --type=merge -p '{"data":{"outputs.conf":"[OUTPUT]\n    Name          http\n    Match         *\n    Host          wrong-host-that-does-not-exist\n    Port          8123\n    URI           /?query=INSERT%20INTO%20otel_logs%20FORMAT%20JSONEachRow\n    Format        json_lines\n    Retry_Limit   5\n"}}'

        print_info "Restarting FluentBit DaemonSet..."
        kubectl -n ${namespace} rollout restart daemonset/fluentbit
      '';
      fixAction = ''
        kubectl apply -k k8s/fluentbit/ || kubectl apply -f k8s/fluentbit/

        print_info "Restarting FluentBit DaemonSet..."
        kubectl -n ${namespace} rollout restart daemonset/fluentbit
      '';
      waitAction = "kubectl -n ${namespace} rollout status daemonset/fluentbit --timeout=120s";
      verifyCmd = "nix run .#verify-fluentbit-output";
      fixCmd = "nix run .#fix-fluentbit-output";
    };

    clickhouse = {
      description = "ClickHouse";
      breakAction = "kubectl -n ${namespace} scale statefulset/clickhouse --replicas=0";
      fixAction = "kubectl -n ${namespace} scale statefulset/clickhouse --replicas=1";
      waitAction = "kubectl -n ${namespace} wait --for=condition=ready pod -l app=clickhouse --timeout=120s";
      verifyCmd = "nix run .#verify-clickhouse";
      fixCmd = "nix run .#fix-clickhouse";
    };

    clickhouse-table = {
      description = "ClickHouse Table";
      breakAction = ''
        kubectl -n ${namespace} exec -it sts/clickhouse -- \
          clickhouse-client -q "DROP TABLE IF EXISTS default.otel_logs"
      '';
      fixAction = ''
        # Read init.sql content and execute
        INIT_SQL=$(kubectl -n ${namespace} get configmap clickhouse-init -o jsonpath='{.data.init\.sql}' 2>/dev/null || echo "")
        if [ -n "$INIT_SQL" ]; then
          echo "$INIT_SQL" | kubectl -n ${namespace} exec -i sts/clickhouse -- clickhouse-client
          print_pass "otel_logs table recreated from ConfigMap"
        else
          print_warn "Could not find init.sql in ConfigMap, trying local file..."
          if [ -f k8s/clickhouse/init.sql ]; then
            kubectl -n ${namespace} exec -i sts/clickhouse -- clickhouse-client < k8s/clickhouse/init.sql
            print_pass "otel_logs table recreated from local file"
          else
            print_fail "Could not find init.sql"
            exit 1
          fi
        fi
      '';
      waitAction = null;
      verifyCmd = "nix run .#verify-clickhouse";
      fixCmd = "nix run .#fix-clickhouse-table";
    };

    hyperdx = {
      description = "HyperDX";
      breakAction = "kubectl -n ${namespace} scale deployment/hyperdx --replicas=0";
      fixAction = "kubectl -n ${namespace} scale deployment/hyperdx --replicas=1";
      waitAction = "kubectl -n ${namespace} wait --for=condition=ready pod -l app=hyperdx --timeout=180s";
      verifyCmd = "nix run .#verify-hyperdx";
      fixCmd = "nix run .#fix-hyperdx";
    };
  };

  # Generate break scripts
  breakScripts = lib.mapAttrs'
    (name: cfg: {
      name = "break-${name}";
      value = pkgs.writeShellApplication {
        name = "break-${name}";
        runtimeInputs = [ pkgs.kubectl ];
        text = ''
          ${commonFunctions}

          print_header "Breaking ${cfg.description}"
          print_info "Injecting failure..."

          ${cfg.breakAction}

          print_pass "${cfg.description} broken"
          echo "  Run '${cfg.verifyCmd}' to verify failure detection"
          echo "  Run '${cfg.fixCmd}' to restore"
        '';
      };
    })
    breakFixPairs;

  # Generate fix scripts
  fixScripts = lib.mapAttrs'
    (name: cfg: {
      name = "fix-${name}";
      value = pkgs.writeShellApplication {
        name = "fix-${name}";
        runtimeInputs = [ pkgs.kubectl ];
        text = ''
          ${commonFunctions}

          print_header "Fixing ${cfg.description}"
          print_info "Restoring..."

          ${cfg.fixAction}

          ${lib.optionalString (cfg.waitAction != null) ''
          print_info "Waiting for recovery..."
          ${cfg.waitAction}
          ''}

          print_pass "${cfg.description} restored"
        '';
      };
    })
    breakFixPairs;

in
breakScripts // fixScripts
