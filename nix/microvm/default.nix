# MicroVM Module Entry Point
#
# This module provides variant-aware microVM configurations for the OTel demo.
# Three variants are available:
#   - docker: Direct Docker Compose execution (lowest resources)
#   - k3s: K3s lightweight Kubernetes (recommended for most users)
#   - minikube: Full Minikube with Docker driver (most resources)
#
# Usage in flake.nix:
#   nixosConfigurations.microvm-docker = nixpkgs.lib.nixosSystem {
#     system = "x86_64-linux";
#     modules = [
#       microvm.nixosModules.microvm
#       (import ./nix/microvm { variant = "docker"; })
#     ];
#     specialArgs = { inherit self; k8sManifestsPath = ./k8s; };
#   };

{ variant ? "k3s" }:

{ config, lib, pkgs, self, k8sManifestsPath ? null, ... }:

let
  # Import port configuration
  ports = import ../ports.nix;

  # Access flake packages for this system
  packages = self.packages.x86_64-linux;

  # Generate k8s manifests with configuration from ports.nix
  # This replaces static YAML files with Nix-generated ones for consistency
  k8sManifests = if k8sManifestsPath != null then
    import ../k8s { inherit lib pkgs; k8sStaticPath = k8sManifestsPath; }
  else null;

  # Resource allocation per variant
  # Disk sizes in MB: minikube needs more space for container images + data
  resources = {
    docker = { mem = 4096; vcpu = 2; disk = 15360; };
    k3s = { mem = 6144; vcpu = 3; disk = 15360; };
    minikube = { mem = 8192; vcpu = 4; disk = 40960; };  # 40GB for minikube + images
  };

  # Select resources for this variant
  res = resources.${variant};

in {
  imports = [
    ./base.nix
    ./images.nix
    ./variants/${variant}.nix
  ];

  # Pass configuration to submodules
  _module.args = {
    inherit variant ports packages k8sManifests;
  };

  # MicroVM configuration
  microvm = {
    # Use QEMU hypervisor
    hypervisor = "qemu";

    # Variant-specific resource allocation
    mem = res.mem;
    vcpu = res.vcpu;

    # Storage volumes
    volumes = [
      {
        mountPoint = "/var";
        image = "var.img";
        size = res.disk;
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

    # Base port forwards (SSH, services)
    # Variants add their own specific forwards
    forwardPorts = [
      { from = "host"; host.port = ports.hostForwards.ssh; guest.port = ports.services.ssh; }
      { from = "host"; host.port = ports.hostForwards.hyperdxApp; guest.port = ports.services.hyperdxApp; }
      { from = "host"; host.port = ports.hostForwards.clickhouseHttp; guest.port = ports.services.clickhouseHttp; }
      { from = "host"; host.port = ports.hostForwards.clickhouseNative; guest.port = ports.services.clickhouseNative; }
      { from = "host"; host.port = ports.hostForwards.hyperdxApi; guest.port = ports.services.hyperdxApi; }
      { from = "host"; host.port = ports.hostForwards.fluentbitMetrics; guest.port = ports.services.fluentbitMetrics; }
      { from = "host"; host.port = ports.hostForwards.mongodb; guest.port = ports.services.mongodb; }
    ] ++ lib.optionals (variant == "k3s" || variant == "minikube") [
      # NodePort forwards for Kubernetes variants
      { from = "host"; host.port = ports.hostForwards.hyperdxApiNodePort; guest.port = ports.nodePorts.hyperdxApi; }
      { from = "host"; host.port = ports.hostForwards.hyperdxAppNodePort; guest.port = ports.nodePorts.hyperdxApp; }
    ];

    # Socket for virtiofs
    socket = "control.sock";

    # Graphics disabled (headless)
    graphics.enable = false;

    # QEMU configuration for serial console debugging
    # NOTE: The "microvm" machine type has no PCI bus, so we can't use virtio-serial-pci.
    # We use only the ISA serial port (ttyS0) over TCP for boot debugging.
    qemu = {
      # Disable default serial console (we configure a TCP-accessible one)
      serialConsole = false;

      extraArgs = [
        # VM identification (for ps/pgrep matching)
        "-name" "otel-demo,process=otel-demo"

        # Serial console on TCP (ttyS0) - available at early boot
        # The microvm machine type supports ISA serial via -serial
        "-serial" "tcp:127.0.0.1:${toString ports.console.serial},server,nowait"
      ];
    };
  };

  # Console output configuration - send to serial console
  # NOTE: hvc0 (virtio console) not available on microvm machine type (no PCI)
  boot.kernelParams = [
    "console=ttyS0,115200"  # Serial console for boot messages
  ];
}
