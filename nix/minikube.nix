# Minikube lifecycle management
#
# Provides unified commands for managing Minikube deployments:
#   - minikube-up: Start cluster, load images, deploy manifests
#   - minikube-status: Check cluster and pod status
#   - minikube-logs: View pod logs
#   - minikube-down: Graceful stop (preserves data)
#   - minikube-delete: Complete cleanup
#
# Uses the shared minikube module from nix/lib/minikube.nix
#
{ pkgs, lib }:

let
  # Import the unified minikube module
  minikubeLib = import ./lib/minikube.nix { inherit pkgs lib; };

  # Generate host scripts with default image prefix
  scripts = minikubeLib.mkHostScripts { imagePrefix = "/tmp"; };

in
{
  # Re-export the generated scripts with original attribute names
  minikubeUp = scripts.up;
  minikubeStatus = scripts.status;
  minikubeLogs = scripts.logs;
  minikubeDown = scripts.down;
  minikubeDelete = scripts.delete;
}
