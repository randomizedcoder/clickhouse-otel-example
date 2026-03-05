# nix/lib/minikube.nix
#
# Unified Minikube orchestration module.
# Provides shared configuration and script fragments for both host-based
# minikube and MicroVM-embedded minikube deployments.
#
# This module enables maximum reuse by:
# - Centralizing minikube configuration (resources, images, namespace)
# - Providing script fragments for orchestration steps
# - Generating either shell scripts (host) or systemd services (microvm)
#
{ pkgs, lib }:
let
  ports = import ../ports.nix;
  constants = import ../constants.nix { inherit pkgs; };

  # Minikube configuration from constants
  cfg = constants.minikube;
  namespace = cfg.namespace;

  # ─── Script Fragments ──────────────────────────────────────────────────────
  # Reusable shell script fragments for minikube orchestration.
  # These can be composed into full scripts or systemd services.
  #

  # Check if minikube is running
  checkRunningFragment = ''
    minikube_is_running() {
      minikube status 2>/dev/null | grep -q "Running"
    }
  '';

  # Start minikube cluster
  startClusterFragment = { force ? false }: ''
    start_minikube() {
      local cpus="${toString cfg.resources.cpus}"
      local memory="${cfg.resources.memory}"
      local driver="${cfg.driver}"

      if minikube_is_running; then
        echo "Minikube already running"
        return 0
      fi

      echo "Starting Minikube cluster..."
      minikube start \
        --driver="$driver" \
        --cpus="$cpus" \
        --memory="$memory" \
        ${lib.optionalString force "--force"} \
        --wait=all
    }
  '';

  # Load images into minikube
  loadImagesFragment = { imagePathPrefix ? "/tmp" }: ''
    load_minikube_images() {
      local image_path_prefix="${imagePathPrefix}"
      local failed=false

      echo "Loading container images into Minikube..."
      for img in ${lib.concatStringsSep " " cfg.imageNames}; do
        echo "Loading $img..."
        if minikube image load "''${image_path_prefix}/''${img}-image" 2>&1; then
          echo "  Loaded $img"
        else
          echo "  Warning: Failed to load $img (may not exist)"
        fi
      done
    }
  '';

  # Wait for node to be ready
  waitNodeReadyFragment = ''
    wait_for_node() {
      local timeout="${toString cfg.timeouts.nodeReady}"
      echo "Waiting for Kubernetes node to be ready..."
      kubectl wait --for=condition=Ready nodes --all --timeout="''${timeout}s"
    }
  '';

  # Deploy manifests
  deployManifestsFragment = { manifestPath ? "k8s/" }: ''
    deploy_k8s_manifests() {
      local manifest_path="${manifestPath}"
      echo "Deploying Kubernetes manifests..."
      kubectl apply -k "$manifest_path" || kubectl apply -f "$manifest_path" -R
    }
  '';

  # Wait for deployments
  waitDeploymentsFragment = ''
    wait_for_deployments() {
      local timeout="${toString cfg.timeouts.deploymentReady}"
      echo "Waiting for deployments to be ready..."
      kubectl -n ${namespace} wait --for=condition=available deployment --all --timeout="''${timeout}s" || true
      kubectl -n ${namespace} wait --for=condition=Ready pods --all --timeout="''${timeout}s" || true
    }
  '';

  # Stop minikube gracefully
  stopClusterFragment = ''
    stop_minikube() {
      echo "Stopping Minikube..."
      if kubectl get namespace ${namespace} &>/dev/null; then
        echo "Deleting manifests..."
        kubectl delete -k k8s/ --timeout=60s 2>/dev/null || true
      fi
      minikube stop || true
    }
  '';

  # Delete minikube completely
  deleteClusterFragment = ''
    delete_minikube() {
      echo "Deleting Minikube completely..."
      minikube delete --all --purge || true
    }
  '';

  # Get service URLs
  getServiceUrlsFragment = ''
    get_service_urls() {
      echo "Service URLs:"
      kubectl -n ${namespace} get svc 2>/dev/null || true
    }
  '';

  # ─── Combined Script Helpers ───────────────────────────────────────────────
  # Full orchestration scripts combining fragments.
  #

  # All helper functions combined
  allHelpers = ''
    ${checkRunningFragment}
    ${startClusterFragment { force = false; }}
    ${loadImagesFragment { }}
    ${waitNodeReadyFragment}
    ${deployManifestsFragment { }}
    ${waitDeploymentsFragment}
    ${stopClusterFragment}
    ${deleteClusterFragment}
    ${getServiceUrlsFragment}
  '';

  # ─── Host Script Generators ────────────────────────────────────────────────
  # Generate shell scripts for direct minikube on host.
  #

  mkHostScripts = { imagePrefix ? "/tmp" }:
    let
      loadFragment = loadImagesFragment { imagePathPrefix = imagePrefix; };
    in
    {
      # Start minikube, load images, deploy manifests
      up = pkgs.writeShellApplication {
        name = "minikube-up";
        runtimeInputs = with pkgs; [ minikube kubectl docker ];
        text = ''
          set -euo pipefail

          ${checkRunningFragment}
          ${startClusterFragment { force = false; }}
          ${loadFragment}
          ${waitNodeReadyFragment}
          ${deployManifestsFragment { }}
          ${waitDeploymentsFragment}

          echo "=== Starting Minikube ==="
          start_minikube

          echo ""
          echo "=== Loading container images ==="
          load_minikube_images

          echo ""
          echo "=== Deploying manifests ==="
          deploy_k8s_manifests

          echo ""
          echo "=== Waiting for pods ==="
          wait_for_deployments

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
          echo "  kubectl -n ${namespace} exec -it sts/clickhouse -- clickhouse-client"
          echo ""
          echo "LIFECYCLE COMMANDS:"
          echo "  nix run .#minikube-status  - Check cluster and pod status"
          echo "  nix run .#minikube-logs    - View loggen and fluentbit logs"
          echo "  nix run .#minikube-down    - Stop gracefully (preserves data)"
          echo "  nix run .#minikube-delete  - Delete completely"
          echo ""
        '';
      };

      # Check status
      status = pkgs.writeShellApplication {
        name = "minikube-status";
        runtimeInputs = with pkgs; [ minikube kubectl ];
        text = ''
          ${checkRunningFragment}
          ${getServiceUrlsFragment}

          echo "=== Minikube Status ==="
          if minikube_is_running; then
            minikube status
            echo ""
            echo "=== Pod Status ==="
            kubectl -n ${namespace} get pods -o wide 2>/dev/null || echo "Namespace not found"
            echo ""
            echo "=== Service URLs ==="
            get_service_urls
          else
            echo "Minikube is NOT running"
            exit 1
          fi
        '';
      };

      # View logs
      logs = pkgs.writeShellApplication {
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

      # Graceful stop
      down = pkgs.writeShellApplication {
        name = "minikube-down";
        runtimeInputs = with pkgs; [ minikube kubectl ];
        text = ''
          ${stopClusterFragment}

          echo "=== Stopping Minikube gracefully ==="
          stop_minikube

          echo ""
          echo "Minikube stopped. Data preserved."
          echo "To fully delete: nix run .#minikube-delete"
        '';
      };

      # Complete deletion
      delete = pkgs.writeShellApplication {
        name = "minikube-delete";
        runtimeInputs = with pkgs; [ minikube ];
        text = ''
          ${deleteClusterFragment}

          echo "=== Deleting Minikube completely ==="
          delete_minikube
          echo "Minikube deleted."
        '';
      };
    };

  # ─── Systemd Service Generators ────────────────────────────────────────────
  # Generate systemd services for MicroVM-embedded minikube.
  #

  mkSystemdServices = { packages, k8sManifests }:
    let
      # Build image load commands for systemd
      imageLoadCommands = lib.concatMapStrings (img: ''
        echo "Loading ${img}..."
        ${pkgs.minikube}/bin/minikube image load ${packages."${img}-image"}
      '') cfg.imageNames;
    in
    {
      # Start minikube service
      minikube-start = {
        description = "Start Minikube Kubernetes Cluster";
        after = [ "docker.service" "network-online.target" ];
        wants = [ "network-online.target" ];
        wantedBy = [ "multi-user.target" ];

        path = [ pkgs.docker ];

        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          User = "root";
          Environment = "HOME=/root";
          ExecStartPre = "${pkgs.coreutils}/bin/sleep 5";
        };

        script = ''
          # Check if minikube is already running
          if ${pkgs.minikube}/bin/minikube status 2>/dev/null | grep -q "Running"; then
            echo "Minikube already running"
            exit 0
          fi

          # Start minikube with docker driver (--force needed for root)
          ${pkgs.minikube}/bin/minikube start \
            --driver=${cfg.driver} \
            --cpus=${toString (cfg.resources.cpus - 1)} \
            --memory=${toString (cfg.resources.memoryMb - 1024)}m \
            --force \
            --wait=all
        '';

        preStop = ''
          ${pkgs.minikube}/bin/minikube stop || true
        '';
      };

      # Load container images service
      load-container-images = {
        description = "Load OCI images into Minikube";
        after = [ "minikube-start.service" ];
        requires = [ "minikube-start.service" ];
        wantedBy = [ "multi-user.target" ];

        path = [ pkgs.docker ];

        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          User = "root";
          Environment = "HOME=/root";
        };

        script = ''
          set -e

          # Wait for minikube to be ready
          ${pkgs.minikube}/bin/minikube status || exit 1

          echo "Loading container images into Minikube..."
          ${imageLoadCommands}
          echo "All images loaded. Verifying..."
          ${pkgs.minikube}/bin/minikube image ls
        '';
      };

      # Deploy manifests service
      deploy-k8s-manifests = {
        description = "Deploy Kubernetes manifests";
        after = [ "load-container-images.service" ];
        requires = [ "load-container-images.service" ];
        wantedBy = [ "multi-user.target" ];

        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          User = "root";
          Environment = "HOME=/root";
        };

        script = ''
          set -e

          # Wait for kubernetes to be ready
          ${pkgs.kubectl}/bin/kubectl wait --for=condition=Ready nodes --all --timeout=${toString cfg.timeouts.nodeReady}s

          echo "Deploying k8s manifests with kustomize..."
          ${pkgs.kubectl}/bin/kubectl apply -k ${k8sManifests}

          echo "Waiting for deployments to be ready..."
          ${pkgs.kubectl}/bin/kubectl -n ${namespace} wait --for=condition=available deployment --all --timeout=${toString cfg.timeouts.deploymentReady}s || true

          echo "Kubernetes manifests deployed"
          ${pkgs.kubectl}/bin/kubectl -n ${namespace} get all
        '';
      };

      # Minikube tunnel service
      minikube-tunnel = {
        description = "Minikube Tunnel for NodePort Access";
        after = [ "deploy-k8s-manifests.service" ];
        requires = [ "deploy-k8s-manifests.service" ];
        wantedBy = [ "multi-user.target" ];

        path = [ pkgs.docker ];

        serviceConfig = {
          Type = "simple";
          User = "root";
          Environment = "HOME=/root";
          ExecStart = "${pkgs.minikube}/bin/minikube tunnel --cleanup=true";
          Restart = "on-failure";
          RestartSec = "10s";
        };
      };
    };

in
{
  inherit cfg namespace;
  inherit checkRunningFragment startClusterFragment loadImagesFragment;
  inherit waitNodeReadyFragment deployManifestsFragment waitDeploymentsFragment;
  inherit stopClusterFragment deleteClusterFragment getServiceUrlsFragment;
  inherit allHelpers;
  inherit mkHostScripts mkSystemdServices;

  # Re-export useful constants
  imageNames = cfg.imageNames;
  resources = cfg.resources;
  timeouts = cfg.timeouts;
}
