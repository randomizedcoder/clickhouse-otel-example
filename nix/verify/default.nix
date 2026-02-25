# Pipeline verification scripts - modular entry point
# Verify each stage of the logging pipeline and inject failures for testing
{ pkgs }:
let
  shellLib = import ../lib/shell.nix { inherit (pkgs) lib; inherit pkgs; };
in
(import ./positive.nix { inherit pkgs shellLib; })
// (import ./init.nix { inherit pkgs shellLib; })
// (import ./break-fix.nix { inherit pkgs shellLib; })
// (import ./latency.nix { inherit pkgs shellLib; })
  // (import ./test-harness.nix { inherit pkgs shellLib; })
