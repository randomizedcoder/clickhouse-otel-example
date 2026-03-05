# MicroVM configuration with embedded Minikube
#
# Uses the shared minikube module from nix/lib/minikube.nix for systemd services.
# This ensures consistent orchestration between host minikube and microvm minikube.
#
{ config, lib, pkgs, self, flake-inputs, k8sManifestsPath, ... }:

let
  # Import port configuration
  ports = import ./ports.nix;
  constants = import ./constants.nix { inherit pkgs; };

  # Import the unified minikube module
  minikubeLib = import ./lib/minikube.nix { inherit pkgs lib; };

  # Access flake packages for this system
  packages = self.packages.x86_64-linux;

  # Copy k8s manifests to a derivation
  k8sManifests = pkgs.runCommand "k8s-manifests" { } ''
    mkdir -p $out
    cp -r ${k8sManifestsPath}/* $out/
  '';

  # Generate systemd services from the unified minikube module
  minikubeServices = minikubeLib.mkSystemdServices {
    inherit packages k8sManifests;
  };

in
{
  # MicroVM configuration
  microvm = {
    # Use QEMU hypervisor
    hypervisor = "qemu";

    # Resource allocation from shared constants
    mem = minikubeLib.resources.memoryMb;
    vcpu = minikubeLib.resources.cpus;

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

    # QEMU configuration for dual serial consoles
    qemu = {
      # Disable default serial console (we configure TCP-accessible ones)
      serialConsole = false;

      extraArgs = [
        # VM identification (for ps/pgrep matching)
        "-name" "otel-demo,process=otel-demo"

        # Serial console on TCP (ttyS0) - slow but early boot access
        "-serial" "tcp:127.0.0.1:${toString ports.console.serial},server,nowait"

        # Virtio console (hvc0) - high-speed, requires drivers
        "-device" "virtio-serial-pci"
        "-chardev" "socket,id=virtcon,port=${toString ports.console.virtio},host=127.0.0.1,server=on,wait=off"
        "-device" "virtconsole,chardev=virtcon"
      ];
    };
  };

  # NixOS configuration
  system.stateVersion = "24.05";

  # Console output configuration - send to both serial and virtio
  boot.kernelParams = [
    "console=ttyS0,115200"  # Serial first (early boot messages)
    "console=hvc0"          # Virtio second (becomes primary after driver loads)
  ];

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

  # Systemd services from unified minikube module
  systemd.services.minikube-start = minikubeServices.minikube-start;
  systemd.services.load-container-images = minikubeServices.load-container-images;
  systemd.services.deploy-k8s-manifests = minikubeServices.deploy-k8s-manifests;
  systemd.services.minikube-tunnel = minikubeServices.minikube-tunnel;

  # Enable nix flakes in the VM
  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  # Journal configuration for logging
  services.journald.extraConfig = ''
    SystemMaxUse=500M
    RuntimeMaxUse=100M
  '';
}
