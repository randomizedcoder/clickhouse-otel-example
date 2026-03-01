# Minikube lifecycle management
#
# Provides unified commands for managing Minikube deployments:
#   - minikube-up: Start cluster, load images, deploy manifests
#   - minikube-status: Check cluster and pod status
#   - minikube-logs: View pod logs
#   - minikube-down: Graceful stop (preserves data)
#   - minikube-delete: Complete cleanup
{ pkgs, lib }:

let
  namespace = "otel-demo";

  # List of images to load
  imageNames = [ "loggen" "fluentbit" "clickhouse" "mongodb" "hyperdx" "otel-collector" ];
in
{
  # Start minikube, load images, deploy manifests
  minikubeUp = pkgs.writeShellApplication {
    name = "minikube-up";
    runtimeInputs = with pkgs; [ minikube kubectl docker ];
    text = ''
      set -euo pipefail

      echo "=== Starting Minikube ==="
      if ! minikube status &>/dev/null; then
        minikube start --cpus=4 --memory=8g --driver=docker
      else
        echo "Minikube already running"
      fi

      echo ""
      echo "=== Loading container images ==="
      for img in ${lib.concatStringsSep " " imageNames}; do
        echo "Loading $img..."
        docker save "$img:latest" 2>/dev/null | minikube image load - || echo "  (skipped - not found locally)"
      done

      echo ""
      echo "=== Deploying manifests ==="
      kubectl apply -k k8s/

      echo ""
      echo "=== Waiting for pods ==="
      kubectl -n ${namespace} wait --for=condition=Ready pods --all --timeout=300s || true

      echo ""
      echo "=============================================="
      echo "  OTel Demo Stack Started (Minikube)"
      echo "=============================================="
      echo ""
      echo "ACCESS POINTS:"
      echo "  HyperDX UI:  minikube service -n ${namespace} hyperdx --url"
      echo "  ClickHouse:  minikube service -n ${namespace} clickhouse --url"
      echo ""
      echo "VIEW LOGGEN LOGS:"
      echo "  kubectl -n ${namespace} logs -f deployment/loggen"
      echo ""
      echo "QUERY CLICKHOUSE:"
      echo "  # Count logs"
      echo "  kubectl -n ${namespace} exec -it sts/clickhouse -- \\"
      echo "    clickhouse-client --query 'SELECT count() FROM otel_logs'"
      echo ""
      echo "  # View recent logs"
      echo "  kubectl -n ${namespace} exec -it sts/clickhouse -- \\"
      echo "    clickhouse-client --query 'SELECT * FROM otel_logs ORDER BY Timestamp DESC LIMIT 5'"
      echo ""
      echo "  # Interactive CLI"
      echo "  kubectl -n ${namespace} exec -it sts/clickhouse -- clickhouse-client"
      echo ""
      echo "  # Compare pipeline latencies"
      echo "  kubectl -n ${namespace} exec -it sts/clickhouse -- clickhouse-client --query \\"
      echo "    \"SELECT extractTextFromHTML(Body) as pipeline, count() as logs, \\"
      echo "     round(avg(IngestionTimestamp - Timestamp) * 1000) as avg_latency_ms \\"
      echo "     FROM otel_logs WHERE Timestamp > now() - INTERVAL 5 MINUTE \\"
      echo "     GROUP BY pipeline ORDER BY avg_latency_ms\""
      echo ""
      echo "LIFECYCLE COMMANDS:"
      echo "  nix run .#minikube-status  - Check cluster and pod status"
      echo "  nix run .#minikube-logs    - View loggen and fluentbit logs"
      echo "  nix run .#minikube-down    - Stop gracefully (preserves data)"
      echo "  nix run .#minikube-delete  - Delete completely"
      echo ""
    '';
  };

  # Check minikube and pod status
  minikubeStatus = pkgs.writeShellApplication {
    name = "minikube-status";
    runtimeInputs = with pkgs; [ minikube kubectl ];
    text = ''
      echo "=== Minikube Status ==="
      if minikube status &>/dev/null; then
        minikube status
        echo ""
        echo "=== Pod Status ==="
        kubectl -n ${namespace} get pods -o wide 2>/dev/null || echo "Namespace not found"
        echo ""
        echo "=== Service URLs ==="
        kubectl -n ${namespace} get svc 2>/dev/null || true
      else
        echo "Minikube is NOT running"
        exit 1
      fi
    '';
  };

  # View logs from all pods
  minikubeLogs = pkgs.writeShellApplication {
    name = "minikube-logs";
    runtimeInputs = with pkgs; [ kubectl ];
    text = ''
      echo "=== Loggen logs ==="
      kubectl -n ${namespace} logs -l app=loggen --tail=20 2>/dev/null || echo "(not running)"
      echo ""
      echo "=== FluentBit logs ==="
      kubectl -n ${namespace} logs -l app=fluentbit --tail=10 2>/dev/null || echo "(not running)"
    '';
  };

  # Graceful stop - delete manifests, stop minikube
  minikubeDown = pkgs.writeShellApplication {
    name = "minikube-down";
    runtimeInputs = with pkgs; [ minikube kubectl ];
    text = ''
      echo "=== Stopping Minikube gracefully ==="

      if kubectl get namespace ${namespace} &>/dev/null; then
        echo "Deleting manifests..."
        kubectl delete -k k8s/ --timeout=60s || true
      fi

      echo "Stopping minikube..."
      minikube stop || true

      echo ""
      echo "Minikube stopped. Data preserved."
      echo "To fully delete: nix run .#minikube-delete"
    '';
  };

  # Force delete - complete cleanup
  minikubeDelete = pkgs.writeShellApplication {
    name = "minikube-delete";
    runtimeInputs = with pkgs; [ minikube ];
    text = ''
      echo "=== Deleting Minikube completely ==="
      minikube delete --all --purge || true
      echo "Minikube deleted."
    '';
  };
}
