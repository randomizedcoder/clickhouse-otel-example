{
  description = "ClickHouse OpenTelemetry Pipeline Demo";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    microvm = {
      url = "github:astro/microvm.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, flake-utils, microvm }:
    let
      # MicroVM variants - defined once, used everywhere
      microvmVariants = [ "docker" "k3s" "minikube" ];
      microvmNames = map (v: "microvm-${v}") microvmVariants;
    in
    flake-utils.lib.eachDefaultSystem
      (system:
        let
          pkgs = import nixpkgs {
            inherit system;
            config.allowUnfree = true;
          };

          # Go application package
          goApp = pkgs.callPackage ./nix/go-app.nix { };

          # FluentBit module with parameterized configuration
          fluentbitModule = pkgs.callPackage ./nix/fluentbit.nix {
            inherit (pkgs) fluent-bit;
          };
          fluentbit = fluentbitModule.package;

          # ClickHouse module with parameterized configuration
          clickhouseModule = pkgs.callPackage ./nix/clickhouse.nix { };
          clickhouse = clickhouseModule.package;

          # Minimal ClickHouse build (smaller binary, fewer features)
          # See docs/CLICKHOUSE_SIZE_OPTIMIZATION.md
          clickhouseMinimalModule = pkgs.callPackage ./nix/clickhouse.nix { useMinimal = true; };
          clickhouseMinimal = clickhouseMinimalModule.package;

          # HyperDX package (uses Yarn Berry v4)
          hyperdx = pkgs.callPackage ./nix/hyperdx.nix {
            inherit (pkgs) yarn-berry inter ibm-plex roboto roboto-mono;
          };

          # Container images
          containers = pkgs.callPackage ./nix/containers.nix {
            inherit goApp fluentbit clickhouse hyperdx;
          };

          # Container images with minimal ClickHouse
          containersMinimal = pkgs.callPackage ./nix/containers.nix {
            inherit goApp fluentbit hyperdx;
            clickhouse = clickhouseMinimal;
          };

          # Docker Compose generator (for running without MicroVM)
          compose = import ./nix/docker-compose.nix {
            lib = pkgs.lib;
            inherit pkgs;
            inherit (pkgs) writeText;
          };

          # Verification scripts (modular)
          verify = pkgs.callPackage ./nix/verify { };

          # Auto-discover verify script names
          verifyScriptNames = verify._scriptNames;

          # Generate verify apps using genAttrs
          verifyApps = pkgs.lib.genAttrs verifyScriptNames (name: {
            type = "app";
            program = "${verify.${name}}/bin/${name}";
          });

        in
        {
          # Packages
          packages = {
            loggen = goApp;
            fluentbit = fluentbit;
            clickhouse-minimal = clickhouseMinimal;
            hyperdx = hyperdx;

            # OCI container images
            loggen-image = containers.loggenImage;
            fluentbit-image = containers.fluentbitImage;
            clickhouse-image = containers.clickhouseImage;
            clickhouse-minimal-image = containersMinimal.clickhouseImage;
            mongodb-image = containers.mongodbImage;
            ferretdb-image = containers.ferretdbImage;
            hyperdx-image = containers.hyperdxImage;
            all-images = containers.allImages;

            default = goApp;
          };

          devShells.default = pkgs.callPackage ./nix/devshell.nix {
            inherit verifyScriptNames;
          };

          formatter = pkgs.nixpkgs-fmt;

          # Apps for running
          apps = {
            loggen = {
              type = "app";
              program = "${goApp}/bin/loggen";
            };

            test = {
              type = "app";
              program = toString (pkgs.writeShellScript "test" ''
                set -e
                cd ${self}
                ${pkgs.go_1_26}/bin/go test -v ./...
              '');
            };

            test-race = {
              type = "app";
              program = toString (pkgs.writeShellScript "test-race" ''
                set -e
                cd ${self}
                CGO_ENABLED=1 ${pkgs.go_1_26}/bin/go test -race -v ./...
              '');
            };

            load-images = {
              type = "app";
              program = "${containers.loadScript}";
            };

            # Docker Compose apps (run stack without MicroVM)
            compose-up = {
              type = "app";
              program = "${compose.composeUp}/bin/compose-up";
            };

            compose-down = {
              type = "app";
              program = "${compose.composeDown}/bin/compose-down";
            };

            compose-logs = {
              type = "app";
              program = "${compose.composeLogs}/bin/compose-logs";
            };

            compose-ps = {
              type = "app";
              program = "${compose.composePs}/bin/compose-ps";
            };

            compose-setup = {
              type = "app";
              program = "${compose.composeSetup}/bin/compose-setup";
            };

            # Convenience scripts for VM management (using writeShellApplication for shellcheck)
            stop-vm = {
              type = "app";
              program = "${pkgs.writeShellApplication {
                name = "stop-vm";
                runtimeInputs = [ pkgs.procps ];
                text = ''
                  echo "Stopping any running MicroVMs..."
                  pkill -9 -f "qemu.*otel-demo" && echo "VMs stopped" || echo "No VMs running"
                '';
              }}/bin/stop-vm";
            };

            clean-vm = {
              type = "app";
              program = "${pkgs.writeShellApplication {
                name = "clean-vm";
                runtimeInputs = [ pkgs.procps pkgs.coreutils ];
                text = ''
                  echo "Cleaning up MicroVM state..."
                  pkill -9 -f "qemu.*otel-demo" || true
                  rm -f var.img control.sock
                  echo "Cleaned: var.img and control.sock removed"
                  echo "Run 'nix run .#microvm' to start fresh"
                '';
              }}/bin/clean-vm";
            };
          } // verifyApps // (if system == "x86_64-linux" then
          # MicroVM runners (x86_64-linux only)
            pkgs.lib.genAttrs (microvmNames ++ [ "microvm" ])
              (name: {
                type = "app";
                program = "${self.nixosConfigurations.${name}.config.microvm.declaredRunner}/bin/microvm-run";
              })
          else { });

          checks = import ./nix/checks.nix { inherit self pkgs; };
        }
      ) // {
      # NixOS configurations (system-independent)
      nixosConfigurations =
        let
          mkMicroVM = variant: nixpkgs.lib.nixosSystem {
            system = "x86_64-linux";
            modules = [
              microvm.nixosModules.microvm
              (import ./nix/microvm { inherit variant; })
            ];
            specialArgs = {
              inherit self;
              k8sManifestsPath = ./k8s;
            };
          };
        in
        nixpkgs.lib.genAttrs microvmNames
          (name: mkMicroVM (nixpkgs.lib.removePrefix "microvm-" name))
        // { microvm = mkMicroVM "minikube"; }; # Legacy alias

      nixosModules = nixpkgs.lib.genAttrs microvmNames
        (name: import ./nix/microvm { variant = nixpkgs.lib.removePrefix "microvm-" name; });
    };
}
