# K3s Variant Configuration
#
# This variant uses K3s, a lightweight Kubernetes distribution.
# K3s uses containerd internally and includes kubectl.
#
# Resource allocation: 6GB RAM, 3 vCPUs, 15GB disk
#
# Services:
#   - k3s.service: K3s server (NixOS service)
#   - load-images.service: Loads images into containerd
#   - deploy-manifests.service: Applies Kubernetes manifests

{ config, lib, pkgs, images, packages, k8sManifests, ... }:

let
  microvmLib = import ../../lib/microvm.nix { inherit lib pkgs; };
  loadImagesScript = microvmLib.mkLoadImagesScript {
    variant = "k3s";
    inherit packages pkgs;
  };
in
{
  # Enable K3s
  services.k3s = {
    enable = true;
    role = "server";
    extraFlags = toString [
      "--disable=traefik" # We don't need ingress for demo
      "--disable=servicelb" # Use NodePort instead
    ];
  };

  # K3s-specific packages
  environment.systemPackages = lib.mkAfter (with pkgs; [
    k3s
    kustomize
  ]);

  # Load container images into containerd
  systemd.services.load-images = microvmLib.mkOneshotService {
    description = "Load OCI images into K3s containerd";
    after = [ "k3s.service" ];
    requires = [ "k3s.service" ];

    script = ''
      set -e

      # Wait for K3s to be ready
      echo "Waiting for K3s to be ready..."
      until ${pkgs.k3s}/bin/k3s kubectl get nodes 2>/dev/null | grep -q " Ready"; do
        sleep 2
      done

      echo "Loading container images into K3s containerd..."
      ${loadImagesScript}

      echo "All images loaded. Verifying..."
      ${pkgs.k3s}/bin/k3s ctr images ls
    '';
  };

  # Deploy Kubernetes manifests
  systemd.services.deploy-manifests = microvmLib.mkOneshotService {
    description = "Deploy Kubernetes manifests";
    after = [ "load-images.service" ];
    requires = [ "load-images.service" ];

    script = ''
      set -e

      # Wait for kubernetes to be ready
      ${pkgs.k3s}/bin/k3s kubectl wait --for=condition=Ready nodes --all --timeout=120s

      echo "Deploying k8s manifests with kustomize..."
      ${pkgs.k3s}/bin/k3s kubectl apply -k ${k8sManifests.default}

      echo "Waiting for deployments to be ready..."
      ${pkgs.k3s}/bin/k3s kubectl -n otel-demo wait --for=condition=available deployment --all --timeout=300s || true

      echo "Kubernetes manifests deployed"
      ${pkgs.k3s}/bin/k3s kubectl -n otel-demo get all
    '';
  };
}
