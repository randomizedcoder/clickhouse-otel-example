# MicroVM helper functions for reducing systemd service boilerplate
{ lib, pkgs }:

{
  # Create a oneshot systemd service with common defaults
  # Usage:
  #   mkOneshotService {
  #     name = "load-images";
  #     description = "Load OCI images";
  #     after = [ "k3s.service" ];
  #     requires = [ "k3s.service" ];
  #     path = [ pkgs.k3s ];
  #     environment = { HOME = "/root"; };
  #     script = "...";
  #   }
  mkOneshotService =
    { description
    , after ? [ ]
    , requires ? [ ]
    , wants ? [ ]
    , path ? [ ]
    , environment ? { }
    , preStart ? null
    , script
    , user ? "root"
    }:
    {
      inherit description after requires wants path;
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = user;
      } // lib.optionalAttrs (environment != { }) {
        Environment = lib.mapAttrsToList (k: v: "${k}=${v}") environment;
      } // lib.optionalAttrs (preStart != null) {
        ExecStartPre = preStart;
      };

      inherit script;
    };

  # Create a simple (long-running) systemd service
  mkSimpleService =
    { description
    , after ? [ ]
    , requires ? [ ]
    , wants ? [ ]
    , path ? [ ]
    , environment ? { }
    , execStart
    , restart ? "on-failure"
    , restartSec ? "10s"
    , user ? "root"
    }:
    {
      inherit description after requires wants path;
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        Type = "simple";
        User = user;
        ExecStart = execStart;
        Restart = restart;
        RestartSec = restartSec;
      } // lib.optionalAttrs (environment != { }) {
        Environment = lib.mapAttrsToList (k: v: "${k}=${v}") environment;
      };
    };

  # Generate image loading script for a variant
  # This reuses the loadCommands pattern from images.nix
  mkLoadImagesScript = { variant, packages, pkgs }:
    let
      loadCommands = {
        docker = image: "${pkgs.docker}/bin/docker load < ${image}";
        k3s = image: "${pkgs.k3s}/bin/k3s ctr images import ${image}";
        minikube = image: "${pkgs.minikube}/bin/minikube image load ${image}";
      };

      images = [
        { name = "loggen"; path = packages.loggen-image; }
        { name = "fluentbit"; path = packages.fluentbit-image; }
        { name = "clickhouse"; path = packages.clickhouse-image; }
        { name = "mongodb"; path = packages.mongodb-image; }
        { name = "hyperdx"; path = packages.hyperdx-image; }
      ];
    in
    lib.concatMapStringsSep "\n"
      (img: ''
        echo "Loading ${img.name}..."
        ${loadCommands.${variant} img.path}
      '')
      images;
}
