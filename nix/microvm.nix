{ config, lib, pkgs, self, flake-inputs, k8sManifestsPath, ... }:

let
  # Import port configuration
  ports = import ./ports.nix;

  # Access flake packages for this system
  packages = self.packages.x86_64-linux;

  # Copy k8s manifests to a derivation
  k8sManifests = pkgs.runCommand "k8s-manifests" { } ''
    mkdir -p $out
    cp -r ${k8sManifestsPath}/* $out/
  '';
in
{
  # MicroVM configuration
  microvm = {
    # Use QEMU hypervisor
    hypervisor = "qemu";

    # Resource allocation - 8GB RAM, 4 CPUs as specified
    mem = 8192;
    vcpu = 4;

    # Storage volumes
    volumes = [
      {
        mountPoint = "/var";
        image = "var.img";
        size = 20480; # 20GB for container images and data
      }
    ];

    # Network interface with user-mode networking
    interfaces = [
      {
        type = "user";
        id = "eth0";
        mac = "02:00:00:00:00:01";
      }
    ];

    # Port forwards using non-standard ports (2XXXX prefix)
    forwardPorts = [
      { from = "host"; host.port = ports.hostForwards.ssh; guest.port = ports.services.ssh; }
      { from = "host"; host.port = ports.hostForwards.hyperdxApp; guest.port = ports.services.hyperdxApp; }
      { from = "host"; host.port = ports.hostForwards.clickhouseHttp; guest.port = ports.services.clickhouseHttp; }
      { from = "host"; host.port = ports.hostForwards.clickhouseNative; guest.port = ports.services.clickhouseNative; }
      { from = "host"; host.port = ports.hostForwards.hyperdxApi; guest.port = ports.services.hyperdxApi; }
      { from = "host"; host.port = ports.hostForwards.fluentbitMetrics; guest.port = ports.services.fluentbitMetrics; }
      { from = "host"; host.port = ports.hostForwards.mongodb; guest.port = ports.services.mongodb; }
      # NodePort forwards (minikube tunnel exposes these on VM localhost)
      { from = "host"; host.port = ports.hostForwards.hyperdxApiNodePort; guest.port = ports.nodePorts.hyperdxApi; }
      { from = "host"; host.port = ports.hostForwards.hyperdxAppNodePort; guest.port = ports.nodePorts.hyperdxApp; }
    ];

    # Socket for virtiofs
    socket = "control.sock";

    # Graphics disabled (headless)
    graphics.enable = false;
  };

  # NixOS configuration
  system.stateVersion = "24.05";

  # Basic system configuration
  networking = {
    hostName = "otel-demo";
    firewall.enable = false; # Disable for easier demo access
  };

  # Enable SSH for access
  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "yes";
      PasswordAuthentication = true;
    };
  };

  # Set root password for demo (change in production!)
  users.users.root.initialPassword = "demo";

  # Demo user
  users.users.demo = {
    isNormalUser = true;
    extraGroups = [ "docker" "wheel" ];
    initialPassword = "demo";
  };

  # Allow demo user to sudo
  security.sudo.wheelNeedsPassword = false;

  # Enable Docker for Minikube
  virtualisation.docker = {
    enable = true;
    autoPrune = {
      enable = true;
      dates = "weekly";
    };
  };

  # Install required packages
  environment.systemPackages = with pkgs; [
    # Kubernetes
    minikube
    kubectl
    kubernetes-helm
    kustomize

    # Container tools
    docker
    skopeo

    # Utilities
    vim
    curl
    jq
    htop
    tmux

    # Database client
    clickhouse
  ];

  # Systemd service to start Minikube
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

  # Systemd service to load container images
  systemd.services.load-container-images = {
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

      # Load each image into minikube's docker daemon
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

  # Systemd service to deploy Kubernetes manifests
  systemd.services.deploy-k8s-manifests = {
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

  # Enable nix flakes in the VM
  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  # Journal configuration for logging
  services.journald.extraConfig = ''
    SystemMaxUse=500M
    RuntimeMaxUse=100M
  '';
}
