# Base NixOS Configuration for MicroVM Variants
#
# This module contains shared configuration used by all variants:
# - System settings (hostname, firewall, stateVersion)
# - SSH configuration
# - User accounts (root, demo)
# - Common packages (vim, curl, jq, htop, tmux, clickhouse-client)
# - Nix settings (flakes enabled)
# - Journal configuration

{ config, lib, pkgs, variant, ... }:

{
  # NixOS configuration
  system.stateVersion = "24.05";

  # Basic system configuration
  networking = {
    hostName = "otel-demo-${variant}";
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

  # Common packages for all variants
  environment.systemPackages = with pkgs; [
    # Utilities
    vim
    curl
    jq
    htop
    tmux

    # Container tools
    skopeo

    # Database client
    clickhouse
  ];

  # Enable nix flakes in the VM
  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  # Journal configuration for logging
  services.journald.extraConfig = ''
    SystemMaxUse=500M
    RuntimeMaxUse=100M
  '';
}
