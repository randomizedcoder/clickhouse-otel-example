# nix/services/types.nix
#
# Service type definitions for the OTel demo stack.
# Provides a schema for service definitions that can be rendered
# to Docker Compose or Kubernetes manifests.
#
{ lib }:
rec {
  # ─── Port Definition ───────────────────────────────────────────────────────
  # Defines a port mapping for a service.
  #
  # Fields:
  # - name: Port name (e.g., "http", "native")
  # - containerPort: Port inside the container
  # - hostPort: Port exposed on host (Docker Compose)
  # - nodePort: NodePort for K8s (optional)
  # - protocol: "tcp" or "udp"
  #
  mkPort = { name, containerPort, hostPort ? null, nodePort ? null, protocol ? "tcp" }: {
    inherit name containerPort hostPort nodePort protocol;
  };

  # ─── Volume Definition ─────────────────────────────────────────────────────
  # Defines a volume mount for a service.
  #
  # Fields:
  # - name: Volume name
  # - mountPath: Path inside container
  # - source: Host path or volume name
  # - readOnly: Whether mount is read-only
  #
  mkVolume = { name, mountPath, source ? null, readOnly ? false }: {
    inherit name mountPath source readOnly;
  };

  # ─── Health Check Definition ───────────────────────────────────────────────
  # Defines health check for a service.
  #
  # Types:
  # - http: HTTP GET to path on port
  # - tcp: TCP connection to port
  # - exec: Execute command
  #
  mkHealthCheck = { type, path ? null, port ? null, command ? null, interval ? 10, timeout ? 5, retries ? 3 }: {
    inherit type path port command interval timeout retries;
  };

  # ─── Resource Limits ───────────────────────────────────────────────────────
  # Defines resource limits for a service.
  #
  mkResources = { cpus ? null, memory ? null, cpuRequest ? null, memoryRequest ? null }: {
    limits = { inherit cpus memory; };
    requests = { cpu = cpuRequest; memory = memoryRequest; };
  };

  # ─── Service Definition ────────────────────────────────────────────────────
  # Complete service definition that can be rendered to Compose or K8s.
  #
  # Fields:
  # - name: Service name (DNS name)
  # - containerName: Container name (Compose)
  # - image: Container image
  # - workloadType: "Deployment" or "StatefulSet" (K8s)
  # - replicas: Number of replicas
  # - ports: List of port definitions
  # - env: Environment variables (attr set)
  # - command: Override entrypoint
  # - args: Override CMD
  # - volumes: List of volume definitions
  # - healthCheck: Health check definition
  # - resources: Resource limits
  # - dependsOn: Services this depends on
  # - labels: Additional labels
  # - annotations: Additional annotations
  #
  mkService = {
    name,
    containerName ? null,
    image,
    workloadType ? "Deployment",
    replicas ? 1,
    ports ? [],
    env ? {},
    command ? null,
    args ? null,
    volumes ? [],
    healthCheck ? null,
    resources ? null,
    dependsOn ? [],
    labels ? {},
    annotations ? {},
    configMaps ? [],
    secrets ? [],
  }: {
    inherit name image workloadType replicas ports env command args volumes;
    inherit healthCheck resources dependsOn labels annotations configMaps secrets;
    containerName = if containerName != null then containerName else "otel-${name}";
  };

  # ─── Service Categories ────────────────────────────────────────────────────
  # Categorize services by their role in the stack.
  #
  categories = {
    database = [ "clickhouse" "mongodb" "redpanda" ];
    logging = [ "fluentbit" "otel-collector" ];
    application = [ "loggen" "hyperdx" "gdp" ];
    ui = [ "redpanda-console" ];
  };

  # ─── Workload Types ────────────────────────────────────────────────────────
  workloadTypes = {
    Deployment = {
      kind = "Deployment";
      apiVersion = "apps/v1";
    };
    StatefulSet = {
      kind = "StatefulSet";
      apiVersion = "apps/v1";
    };
    DaemonSet = {
      kind = "DaemonSet";
      apiVersion = "apps/v1";
    };
  };

  # Validation helpers
  validatePort = port:
    assert lib.isInt port.containerPort;
    assert port.protocol == "tcp" || port.protocol == "udp";
    port;

  validateService = service:
    assert lib.isString service.name;
    assert lib.isString service.image;
    assert lib.elem service.workloadType (lib.attrNames workloadTypes);
    service;
}
