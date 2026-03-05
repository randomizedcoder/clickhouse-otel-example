# nix/lifecycle/transports.nix
#
# Transport abstraction layer for lifecycle tests.
# Defines transport primitives that checks use to communicate with services.
#
# Three transport implementations:
# - http: Direct HTTP calls (for docker-compose)
# - kubectl: kubectl exec commands (for host minikube)
# - ssh: SSH + kubectl (for microvm)
#
# Each transport implements the same interface:
# - transport_clickhouse_query <query>
# - transport_http_get <url>
# - transport_exec <pod_label> <command...>
# - transport_check_pod_ready <pod_label>
#
{ pkgs, lib }:
let
  constants = import ./constants.nix { };
  ports = import ../ports.nix;
in
rec {
  # ─── HTTP Transport ────────────────────────────────────────────────────────
  # Direct HTTP calls for docker-compose deployment.
  #
  httpTransport = { clickhouseUrl, hyperdxApiUrl }: ''
    # HTTP Transport Implementation
    CLICKHOUSE_URL="${clickhouseUrl}"
    HYPERDX_API="${hyperdxApiUrl}"

    transport_clickhouse_query() {
      local query="$1"
      curl -sf "$CLICKHOUSE_URL/" -d "$query" 2>/dev/null
    }

    transport_http_get() {
      local url="$1"
      curl -sf "$url" 2>/dev/null
    }

    transport_exec() {
      local container="$1"
      shift
      docker exec "$container" "$@" 2>/dev/null
    }

    transport_check_container_running() {
      local name="$1"
      docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^$name$"
    }

    # For HTTP transport, pod checks are container checks
    transport_check_pod_ready() {
      local label="$1"
      # Extract container name from label (app=name -> otel-name)
      local name="otel-''${label#app=}"
      transport_check_container_running "$name"
    }

    transport_hyperdx_health() {
      local result
      result=$(curl -sf "$HYPERDX_API/health" 2>/dev/null)
      echo "$result" | jq -e '.data == "OK"' >/dev/null 2>&1
    }
  '';

  # ─── Kubectl Transport ─────────────────────────────────────────────────────
  # Direct kubectl exec for host minikube deployment.
  #
  kubectlTransport = { namespace }: ''
    # Kubectl Transport Implementation
    NAMESPACE="${namespace}"

    transport_clickhouse_query() {
      local query="$1"
      kubectl exec -n "$NAMESPACE" clickhouse-0 -- clickhouse-client --query "$query" 2>/dev/null
    }

    transport_http_get() {
      local url="$1"
      # For kubectl transport, we need to exec into a pod that has curl
      # or use port-forward. For simplicity, we'll use exec if the URL is internal.
      if [[ "$url" == http://hyperdx* ]] || [[ "$url" == http://clickhouse* ]]; then
        local host path stripped
        # Remove http:// prefix using bash parameter expansion
        stripped=''${url#http://}
        # Extract host (everything before first : or /)
        host=''${stripped%%[:/]*}
        # Extract path (everything from first / after host)
        if [[ "$stripped" == */* ]]; then
          path="/''${stripped#*/}"
        else
          path="/"
        fi
        kubectl exec -n "$NAMESPACE" hyperdx-0 -- curl -sf "http://$host:8000$path" 2>/dev/null || \
          kubectl exec -n "$NAMESPACE" clickhouse-0 -- curl -sf "$url" 2>/dev/null
      else
        curl -sf "$url" 2>/dev/null
      fi
    }

    transport_exec() {
      local label="$1"
      shift
      local pod_name
      pod_name=$(kubectl get pods -n "$NAMESPACE" -l "$label" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
      if [[ -n "$pod_name" ]]; then
        kubectl exec -n "$NAMESPACE" "$pod_name" -- "$@" 2>/dev/null
      else
        return 1
      fi
    }

    transport_check_pod_ready() {
      local label="$1"
      local ready
      ready=$(kubectl get pods -n "$NAMESPACE" -l "$label" -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
      [[ "$ready" == "True" ]]
    }

    transport_hyperdx_health() {
      local ready
      ready=$(kubectl get pods -n "$NAMESPACE" -l app=hyperdx -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
      [[ "$ready" == "True" ]]
    }

    transport_wait_for_pod() {
      local label="$1"
      local timeout="''${2:-60}"
      kubectl wait --for=condition=ready pod -l "$label" -n "$NAMESPACE" --timeout="''${timeout}s" >/dev/null 2>&1
    }
  '';

  # ─── SSH Transport ─────────────────────────────────────────────────────────
  # SSH + kubectl for MicroVM deployment.
  #
  sshTransport = { sshPort, sshUser, sshPassword, namespace }: ''
    # SSH Transport Implementation
    SSH_PORT="${toString sshPort}"
    SSH_USER="${sshUser}"
    SSH_PASS="${sshPassword}"
    NAMESPACE="${namespace}"

    # SSH command wrapper
    _ssh_cmd() {
      sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=5 -p "$SSH_PORT" "$SSH_USER@localhost" "$@" 2>/dev/null
    }

    transport_clickhouse_query() {
      local query="$1"
      # Use double quotes and escape inner quotes to handle LIKE '%..%' queries properly
      _ssh_cmd "kubectl exec -n $NAMESPACE clickhouse-0 -- clickhouse-client --query \"$query\"" 2>/dev/null | tail -1 | tr -d '[:space:]'
    }

    transport_http_get() {
      local url="$1"
      # Execute curl via SSH
      _ssh_cmd "curl -sf '$url'" 2>/dev/null
    }

    transport_exec() {
      local label="$1"
      shift
      local pod_name
      pod_name=$(_ssh_cmd "kubectl get pods -n $NAMESPACE -l $label -o jsonpath='{.items[0].metadata.name}'" 2>/dev/null | tail -1 | tr -d '[:space:]')
      if [[ -n "$pod_name" ]]; then
        _ssh_cmd "kubectl exec -n $NAMESPACE $pod_name -- $*" 2>/dev/null
      else
        return 1
      fi
    }

    transport_check_pod_ready() {
      local label="$1"
      local ready
      ready=$(_ssh_cmd "kubectl get pods -n $NAMESPACE -l $label -o jsonpath='{.items[0].status.conditions[?(@.type==\"Ready\")].status}'" 2>/dev/null | tail -1 | tr -d '[:space:]')
      [[ "$ready" == "True" ]]
    }

    transport_hyperdx_health() {
      local ready
      ready=$(_ssh_cmd "kubectl get pods -n $NAMESPACE -l app=hyperdx -o jsonpath='{.items[0].status.conditions[?(@.type==\"Ready\")].status}'" 2>/dev/null | tail -1 | tr -d '[:space:]')
      [[ "$ready" == "True" ]]
    }

    transport_wait_for_pod() {
      local label="$1"
      local timeout="''${2:-60}"
      _ssh_cmd "kubectl wait --for=condition=ready pod -l $label -n $NAMESPACE --timeout=''${timeout}s" >/dev/null 2>&1
    }

    transport_ssh_ready() {
      _ssh_cmd "echo ok" 2>/dev/null | grep -q "ok"
    }

    transport_minikube_running() {
      _ssh_cmd "minikube status" 2>/dev/null | grep -q "Running"
    }
  '';

  # ─── Transport Factory ─────────────────────────────────────────────────────
  # Generate transport implementation based on variant.
  #
  mkTransport = { variant }:
    if variant == "docker-compose" then
      httpTransport {
        clickhouseUrl = constants.variants.docker-compose.clickhouseUrl;
        hyperdxApiUrl = constants.variants.docker-compose.hyperdxApiUrl;
      }
    else if variant == "minikube" then
      kubectlTransport {
        namespace = constants.variants.minikube.namespace;
      }
    else if variant == "microvm" then
      sshTransport {
        sshPort = constants.variants.microvm.sshPort;
        sshUser = constants.variants.microvm.sshUser;
        sshPassword = constants.variants.microvm.sshPassword;
        namespace = constants.variants.microvm.namespace;
      }
    else
      throw "Unknown variant: ${variant}";

}
