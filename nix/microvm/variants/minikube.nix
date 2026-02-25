# Minikube Variant Configuration
#
# This variant uses Minikube with the Docker driver.
# It has the highest resource requirements but is most compatible.
#
# Resource allocation: 8GB RAM, 4 vCPUs, 20GB disk
#
# Services:
#   - docker.service: Docker daemon (NixOS service)
#   - minikube-start.service: Starts minikube cluster
#   - load-images.service: Loads images into minikube's Docker
#   - deploy-manifests.service: Applies Kubernetes manifests
#   - minikube-tunnel.service: Exposes NodePorts on localhost

{ config, lib, pkgs, images, packages, k8sManifests, ... }:

{
  # Enable Docker for Minikube
  virtualisation.docker = {
    enable = true;
    autoPrune = {
      enable = true;
      dates = "weekly";
    };
  };

  # Minikube-specific packages
  environment.systemPackages = lib.mkAfter (with pkgs; [
    docker
    minikube
    kubectl
    kubernetes-helm
    kustomize
  ]);

  # Start Minikube
  systemd.services.minikube-start = {
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
      ExecStartPre = "${pkgs.coreutils}/bin/sleep 5"; # Wait for docker
    };

    script = ''
      # Check if minikube is already running
      if ${pkgs.minikube}/bin/minikube status 2>/dev/null | grep -q "Running"; then
        echo "Minikube already running"
        exit 0
      fi

      # Start minikube with docker driver (--force needed for root)
      ${pkgs.minikube}/bin/minikube start \
        --driver=docker \
        --cpus=3 \
        --memory=6g \
        --force \
        --wait=all
    '';

    preStop = ''
      ${pkgs.minikube}/bin/minikube stop || true
    '';
  };

  # Load container images into Minikube
  systemd.services.load-images = {
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

      echo "Loading loggen..."
      ${pkgs.minikube}/bin/minikube image load ${packages.loggen-image}

      echo "Loading fluentbit..."
      ${pkgs.minikube}/bin/minikube image load ${packages.fluentbit-image}

      echo "Loading clickhouse..."
      ${pkgs.minikube}/bin/minikube image load ${packages.clickhouse-image}

      echo "Loading mongodb..."
      ${pkgs.minikube}/bin/minikube image load ${packages.mongodb-image}

      echo "Loading hyperdx..."
      ${pkgs.minikube}/bin/minikube image load ${packages.hyperdx-image}

      echo "All images loaded. Verifying..."
      ${pkgs.minikube}/bin/minikube image ls
    '';
  };

  # Deploy Kubernetes manifests
  systemd.services.deploy-manifests = {
    description = "Deploy Kubernetes manifests";
    after = [ "load-images.service" ];
    requires = [ "load-images.service" ];
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
      ${pkgs.kubectl}/bin/kubectl wait --for=condition=Ready nodes --all --timeout=120s

      echo "Deploying k8s manifests with kustomize..."
      ${pkgs.kubectl}/bin/kubectl apply -k ${k8sManifests}

      echo "Waiting for deployments to be ready..."
      ${pkgs.kubectl}/bin/kubectl -n otel-demo wait --for=condition=available deployment --all --timeout=300s || true

      echo "Kubernetes manifests deployed"
      ${pkgs.kubectl}/bin/kubectl -n otel-demo get all
    '';
  };

  # Minikube tunnel service to expose NodePorts on VM localhost
  systemd.services.minikube-tunnel = {
    description = "Minikube Tunnel for NodePort Access";
    after = [ "deploy-manifests.service" ];
    requires = [ "deploy-manifests.service" ];
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
}
