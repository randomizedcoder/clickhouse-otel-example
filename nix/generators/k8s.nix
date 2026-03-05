# nix/generators/k8s.nix
#
# Kubernetes manifest generator.
# Generates K8s manifests from service definitions.
#
{ pkgs, lib, writeText ? pkgs.writeText }:
let
  ports = import ../ports.nix;
  constants = import ../constants.nix { inherit pkgs; };
  services = import ../services/default.nix { inherit pkgs lib; };
  types = services.types;

  namespace = constants.minikube.namespace;

  # ─── YAML Generation Helpers ───────────────────────────────────────────────
  # Convert Nix values to YAML strings.
  #

  indent = n: str:
    let
      spaces = lib.concatStrings (lib.genList (_: " ") n);
    in
    lib.concatMapStringsSep "\n" (line: "${spaces}${line}") (lib.splitString "\n" str);

  # Convert attr set to YAML env array
  envToYaml = env:
    lib.concatMapStringsSep "\n" (name:
      "- name: ${name}\n  value: \"${toString env.${name}}\""
    ) (lib.attrNames env);

  # Convert ports to YAML
  portsToYaml = portList:
    lib.concatMapStringsSep "\n" (port: ''
      - name: ${port.name}
        containerPort: ${toString port.containerPort}
        protocol: ${lib.toUpper port.protocol}'')
      portList;

  # Convert health check to probe YAML
  healthCheckToProbe = hc:
    if hc.type == "http" then ''
      httpGet:
        path: ${hc.path}
        port: ${if lib.isInt hc.port then toString hc.port else hc.port}
      initialDelaySeconds: 30
      periodSeconds: ${toString hc.interval}
      timeoutSeconds: ${toString hc.timeout}
      failureThreshold: ${toString hc.retries}''
    else if hc.type == "exec" then ''
      exec:
        command: ${builtins.toJSON hc.command}
      initialDelaySeconds: 10
      periodSeconds: ${toString hc.interval}
      timeoutSeconds: ${toString hc.timeout}
      failureThreshold: ${toString hc.retries}''
    else if hc.type == "tcp" then ''
      tcpSocket:
        port: ${if lib.isInt hc.port then toString hc.port else hc.port}
      initialDelaySeconds: 10
      periodSeconds: ${toString hc.interval}
      timeoutSeconds: ${toString hc.timeout}
      failureThreshold: ${toString hc.retries}''
    else "";

  # Convert resources to YAML
  resourcesToYaml = res:
    let
      limits = lib.filterAttrs (_: v: v != null) res.limits;
      requests = lib.filterAttrs (_: v: v != null) res.requests;
    in
    lib.optionalString (limits != {} || requests != {}) ''
      resources:
        ${lib.optionalString (limits != {}) ''
        limits:
          ${lib.concatMapStringsSep "\n  " (k: "${k}: \"${toString limits.${k}}\"") (lib.attrNames limits)}''}
        ${lib.optionalString (requests != {}) ''
        requests:
          ${lib.concatMapStringsSep "\n  " (k: "${k}: \"${toString requests.${k}}\"") (lib.attrNames requests)}''}
    '';

  # ─── Manifest Generators ───────────────────────────────────────────────────
  #

  # Generate Deployment/StatefulSet manifest
  mkWorkload = service:
    let
      kind = types.workloadTypes.${service.workloadType}.kind;
      apiVersion = types.workloadTypes.${service.workloadType}.apiVersion;
      envYaml = if service.env != {} then indent 12 (envToYaml service.env) else "";
      portsYaml = if service.ports != [] then indent 12 (portsToYaml service.ports) else "";
      probeYaml = if service.healthCheck != null then indent 10 (healthCheckToProbe service.healthCheck) else "";
      resourcesYaml = if service.resources != null then indent 10 (resourcesToYaml service.resources) else "";
    in
    ''
      apiVersion: ${apiVersion}
      kind: ${kind}
      metadata:
        name: ${service.name}
        namespace: ${namespace}
        labels:
          app: ${service.name}
          app.kubernetes.io/name: ${service.name}
      spec:
        ${if kind == "StatefulSet" then "serviceName: ${service.name}" else ""}
        replicas: ${toString service.replicas}
        selector:
          matchLabels:
            app: ${service.name}
        template:
          metadata:
            labels:
              app: ${service.name}
          spec:
            containers:
              - name: ${service.name}
                image: ${service.image}
                imagePullPolicy: Never
                ${lib.optionalString (service.command != null) "command: ${builtins.toJSON service.command}"}
                ${lib.optionalString (service.args != null) "args: ${builtins.toJSON service.args}"}
                ${lib.optionalString (service.env != {}) ''
                env:
                  ${envYaml}''}
                ${lib.optionalString (service.ports != []) ''
                ports:
                  ${portsYaml}''}
                ${lib.optionalString (service.healthCheck != null) ''
                readinessProbe:
                  ${probeYaml}
                livenessProbe:
                  ${probeYaml}''}
                ${resourcesYaml}
    '';

  # Generate Service manifest
  mkService = service:
    let
      servicePorts = lib.concatMapStringsSep "\n" (port:
        let
          nodePortStr = if port.nodePort != null then "nodePort: ${toString port.nodePort}" else "";
        in ''
          - name: ${port.name}
            port: ${toString port.containerPort}
            targetPort: ${toString port.containerPort}
            ${nodePortStr}
            protocol: ${lib.toUpper port.protocol}'')
        service.ports;
      serviceType = if lib.any (p: p.nodePort != null) service.ports then "NodePort" else "ClusterIP";
    in
    lib.optionalString (service.ports != []) ''
      ---
      apiVersion: v1
      kind: Service
      metadata:
        name: ${service.name}
        namespace: ${namespace}
        labels:
          app: ${service.name}
      spec:
        type: ${serviceType}
        ports:
          ${servicePorts}
        selector:
          app: ${service.name}
    '';

  # Generate combined manifest for a service
  mkServiceManifest = service: ''
    ${mkWorkload service}
    ${mkService service}
  '';

  # ─── Namespace Manifest ────────────────────────────────────────────────────
  namespaceManifest = writeText "namespace.yaml" ''
    apiVersion: v1
    kind: Namespace
    metadata:
      name: ${namespace}
      labels:
        name: ${namespace}
  '';

  # ─── Generate All Manifests ────────────────────────────────────────────────
  #

  # Generate manifest for each service
  serviceManifests = lib.mapAttrs (name: service:
    writeText "${name}.yaml" (mkServiceManifest service)
  ) services.services;

  # Generate kustomization.yaml
  kustomization = writeText "kustomization.yaml" ''
    apiVersion: kustomize.config.k8s.io/v1beta1
    kind: Kustomization

    namespace: ${namespace}

    resources:
      - namespace.yaml
      ${lib.concatMapStringsSep "\n  " (name: "- ${name}/") (lib.attrNames services.services)}
  '';

in
{
  # Export individual manifest generators
  inherit mkWorkload mkService mkServiceManifest;

  # Export all service manifests
  inherit serviceManifests namespaceManifest kustomization;

  # Generate a complete K8s manifest directory
  k8sManifests = pkgs.runCommand "k8s-manifests-generated" {} ''
    mkdir -p $out

    # Copy namespace
    cp ${namespaceManifest} $out/namespace.yaml

    # Create service directories
    ${lib.concatMapStringsSep "\n" (name: ''
      mkdir -p $out/${name}
      cp ${serviceManifests.${name}} $out/${name}/deployment.yaml
    '') (lib.attrNames services.services)}

    # Copy kustomization
    cp ${kustomization} $out/kustomization.yaml
  '';

  # Export services for composition
  inherit services;
}
