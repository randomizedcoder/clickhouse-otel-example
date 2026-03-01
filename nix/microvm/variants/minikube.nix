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

let
  microvmLib = import ../../lib/microvm.nix { inherit lib pkgs; };
  loadImagesScript = microvmLib.mkLoadImagesScript {
    variant = "minikube";
    inherit packages pkgs;
  };

  # Common environment for minikube commands
  minikubeEnv = { HOME = "/root"; };
in
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
  systemd.services.minikube-start = microvmLib.mkOneshotService {
    description = "Start Minikube Kubernetes Cluster";
    after = [ "docker.service" "network-online.target" ];
    wants = [ "network-online.target" ];
    path = [ pkgs.docker ];
    environment = minikubeEnv;
    preStart = "${pkgs.coreutils}/bin/sleep 5"; # Wait for docker

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
  };

  # Load container images into Minikube
  systemd.services.load-images = microvmLib.mkOneshotService {
    description = "Load OCI images into Minikube";
    after = [ "minikube-start.service" ];
    requires = [ "minikube-start.service" ];
    path = [ pkgs.docker ];
    environment = minikubeEnv;

    script = ''
      set -e

      # Wait for minikube to be ready
      ${pkgs.minikube}/bin/minikube status || exit 1

      echo "Loading container images into Minikube..."
      ${loadImagesScript}

      echo "All images loaded. Verifying..."
      ${pkgs.minikube}/bin/minikube image ls
    '';
  };

  # Deploy Kubernetes manifests
  systemd.services.deploy-manifests = microvmLib.mkOneshotService {
    description = "Deploy Kubernetes manifests";
    after = [ "load-images.service" ];
    requires = [ "load-images.service" ];
    environment = minikubeEnv;

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
  systemd.services.minikube-tunnel = microvmLib.mkSimpleService {
    description = "Minikube Tunnel for NodePort Access";
    after = [ "deploy-manifests.service" ];
    requires = [ "deploy-manifests.service" ];
    path = [ pkgs.docker ];
    environment = minikubeEnv;
    execStart = "${pkgs.minikube}/bin/minikube tunnel --cleanup=true";
  };
}
