# nix/generators/default.nix
#
# Entry point for manifest generators.
# Exports both Docker Compose and Kubernetes generators.
#
{ pkgs, lib }:
let
  compose = import ./compose.nix { inherit pkgs lib; writeText = pkgs.writeText; };
  k8s = import ./k8s.nix { inherit pkgs lib; writeText = pkgs.writeText; };
in
{
  # Docker Compose generator
  compose = {
    inherit (compose) composeFile composeContent serviceToCompose;
  };

  # Kubernetes generator
  k8s = {
    inherit (k8s) k8sManifests serviceManifests namespaceManifest kustomization;
    inherit (k8s) mkWorkload mkService mkServiceManifest;
  };

  # Services (shared between generators)
  services = compose.services;
}
