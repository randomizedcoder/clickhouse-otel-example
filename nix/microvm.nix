{ config, lib, pkgs, self, flake-inputs, ... }:

let
  # Import port configuration
  ports = import ./ports.nix;
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
        size = 20480;  # 20GB for container images and data
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
    firewall.enable = false;  # Disable for easier demo access
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

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = "root";
      Environment = "HOME=/root";
      ExecStartPre = "${pkgs.coreutils}/bin/sleep 5";  # Wait for docker
    };

    script = ''
      # Check if minikube is already running
      if ${pkgs.minikube}/bin/minikube status 2>/dev/null | grep -q "Running"; then
        echo "Minikube already running"
        exit 0
      fi

      # Start minikube with docker driver
      ${pkgs.minikube}/bin/minikube start \
        --driver=docker \
        --cpus=3 \
        --memory=6g \
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

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = "root";
      Environment = "HOME=/root";
    };

    script = ''
      # Wait for minikube to be fully ready
      ${pkgs.minikube}/bin/minikube status || exit 1

      echo "Loading container images into Minikube..."

      # The images will be available in /run/current-system/sw/share/images/
      # or we can build them on-demand

      # For now, just verify minikube is ready
      ${pkgs.kubectl}/bin/kubectl get nodes

      echo "Container images ready"
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
      # Wait for kubernetes to be ready
      ${pkgs.kubectl}/bin/kubectl wait --for=condition=Ready nodes --all --timeout=120s

      # Apply manifests if they exist
      if [ -d /etc/kubernetes/manifests ]; then
        ${pkgs.kubectl}/bin/kubectl apply -f /etc/kubernetes/manifests/
      fi

      echo "Kubernetes manifests deployed"
    '';
  };

  # Copy Kubernetes manifests to the VM
  environment.etc = {
    "kubernetes/manifests/namespace.yaml".text = ''
      apiVersion: v1
      kind: Namespace
      metadata:
        name: otel-demo
        labels:
          app.kubernetes.io/name: otel-demo
    '';
  };

  # Enable nix flakes in the VM
  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  # Journal configuration for logging
  services.journald.extraConfig = ''
    SystemMaxUse=500M
    RuntimeMaxUse=100M
  '';
}
