# Shared utilities for the clickhouse-otel-example Nix codebase
{ lib, pkgs }:
{
  shell = import ./shell.nix { inherit lib pkgs; };
  containers = import ./containers.nix { inherit lib pkgs; };
  apps = import ./apps.nix { inherit lib; };
}
