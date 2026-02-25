# Docker Variant Configuration
#
# This variant runs containers directly with Docker Compose.
# It has the lowest resource requirements of all variants.
#
# Resource allocation: 4GB RAM, 2 vCPUs, 15GB disk
#
# Services:
#   - load-images.service: Loads Nix-built images into Docker
#   - otel-demo.service: Runs docker compose up

{ config, lib, pkgs, images, loadImagesScript, ... }:

{
  # Enable Docker
  virtualisation.docker = {
    enable = true;
    autoPrune = {
      enable = true;
      dates = "weekly";
    };
  };

  # Docker-specific packages
  environment.systemPackages = lib.mkAfter (with pkgs; [
    docker
    docker-compose
  ]);

  # Load container images into Docker
  systemd.services.load-images = {
    description = "Load OCI images into Docker";
    after = [ "docker.service" ];
    requires = [ "docker.service" ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = "root";
    };

    script = loadImagesScript;
  };

  # Docker Compose service
  # TODO: Phase 2 will generate docker-compose.yaml from Nix
  systemd.services.otel-demo = {
    description = "OTel Demo Stack (Docker Compose)";
    after = [ "load-images.service" ];
    requires = [ "load-images.service" ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = "root";
      WorkingDirectory = "/etc/otel-demo";
    };

    # Placeholder - will be implemented in Phase 2
    script = ''
      echo "Docker Compose variant - to be implemented in Phase 2"
      # ${pkgs.docker-compose}/bin/docker compose up -d
    '';
  };
}
