# Container Image Loading Utilities
#
# This module provides variant-aware container image loading.
# Each variant uses a different method to load images:
#   - docker: `docker load < image.tar.gz`
#   - k3s: `k3s ctr images import image.tar.gz`
#   - minikube: `minikube image load image.tar.gz`
#
# The module exposes:
#   - config.microvm.images: attrset of image paths
#   - loadCommand function via _module.args

{ config, lib, pkgs, variant, packages, ... }:

let
  # All container images from the flake
  images = {
    loggen = packages.loggen-image;
    fluentbit = packages.fluentbit-image;
    clickhouse = packages.clickhouse-image;
    mongodb = packages.mongodb-image;
    hyperdx = packages.hyperdx-image;
  };

  # Variant-specific image load commands
  loadCommands = {
    docker = image: "${pkgs.docker}/bin/docker load < ${image}";
    k3s = image: "${pkgs.k3s}/bin/k3s ctr images import ${image}";
    minikube = image: "${pkgs.minikube}/bin/minikube image load ${image}";
  };

  # Generate script to load all images
  mkLoadImagesScript = { variant, images }: ''
    set -e

    echo "Loading container images for ${variant} variant..."

    ${lib.concatStringsSep "\n" (lib.mapAttrsToList (name: image: ''
      echo "Loading ${name}..."
      ${loadCommands.${variant} image}
    '') images)}

    echo "All images loaded successfully."
  '';

in {
  options.microvm.images = lib.mkOption {
    type = lib.types.attrsOf lib.types.package;
    default = images;
    description = "Container images to load into the VM";
  };

  config = {
    # Pass image loading utilities to other modules
    _module.args = {
      inherit images;
      loadCommand = loadCommands.${variant};
      loadImagesScript = mkLoadImagesScript { inherit variant images; };
    };
  };
}
