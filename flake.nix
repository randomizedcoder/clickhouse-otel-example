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

          # Verification scripts (modular)
          verify = pkgs.callPackage ./nix/verify { };

          # Import app helpers
          appsLib = import ./nix/lib/apps.nix { inherit (pkgs) lib; };

          # All verify script names for genAttrs
          verifyScriptNames = [
            # Positive verification
            "verify-loggen"
            "verify-fluentbit"
            "verify-fluentbit-output"
            "verify-clickhouse"
            "verify-hyperdx"
            "verify-pipeline"
            # Initialization
            "init-clickhouse"
            # Break scripts
            "break-loggen"
            "break-fluentbit"
            "break-fluentbit-lua"
            "break-fluentbit-output"
            "break-clickhouse"
            "break-clickhouse-table"
            "break-hyperdx"
            # Fix scripts
            "fix-loggen"
            "fix-fluentbit"
            "fix-fluentbit-lua"
            "fix-fluentbit-output"
            "fix-clickhouse"
            "fix-clickhouse-table"
            "fix-hyperdx"
            # Latency measurement
            "measure-latency"
            "measure-latency-active"
            # Test harness
            "test-verify-scripts"
          ];

          # Generate verify apps using genAttrs
          verifyApps = pkgs.lib.genAttrs verifyScriptNames (name: {
            type = "app";
            program = "${verify.${name}}/bin/${name}";
          });

        in
        {
          # Packages
          packages = {
            # Go application binary
            loggen = goApp;

            # FluentBit binary
            fluentbit = fluentbit;

            # ClickHouse minimal build (smaller binary for OTEL pipeline)
            # See docs/CLICKHOUSE_SIZE_OPTIMIZATION.md
            clickhouse-minimal = clickhouseMinimal;

            # HyperDX
            hyperdx = hyperdx;

            # OCI container images
            loggen-image = containers.loggenImage;
            fluentbit-image = containers.fluentbitImage;
            clickhouse-image = containers.clickhouseImage;
            clickhouse-minimal-image = containersMinimal.clickhouseImage;
            mongodb-image = containers.mongodbImage;
            ferretdb-image = containers.ferretdbImage;
            hyperdx-image = containers.hyperdxImage;

            # All images bundled
            all-images = containers.allImages;

            # Default package
            default = goApp;
          };

          # Development shell
          devShells.default = pkgs.callPackage ./nix/devshell.nix { };

          # Formatter for `nix fmt`
          formatter = pkgs.nixpkgs-fmt;

          # Apps for running
          apps = {
            # Core apps
            loggen = {
              type = "app";
              program = "${goApp}/bin/loggen";
            };

            test = {
              type = "app";
              program = toString (pkgs.writeShellScript "test" ''
                set -e
                cd ${self}
                ${pkgs.go}/bin/go test -v ./...
              '');
            };

            test-race = {
              type = "app";
              program = toString (pkgs.writeShellScript "test-race" ''
                set -e
                cd ${self}
                CGO_ENABLED=1 ${pkgs.go}/bin/go test -race -v ./...
              '');
            };

            load-images = {
              type = "app";
              program = "${containers.loadScript}";
            };
          } // verifyApps // (if system == "x86_64-linux" then {
            # MicroVM runners (x86_64-linux only)
            microvm-docker = {
              type = "app";
              program = toString (
                self.nixosConfigurations.microvm-docker.config.microvm.declaredRunner
              );
            };
            microvm-k3s = {
              type = "app";
              program = toString (
                self.nixosConfigurations.microvm-k3s.config.microvm.declaredRunner
              );
            };
            microvm-minikube = {
              type = "app";
              program = toString (
                self.nixosConfigurations.microvm-minikube.config.microvm.declaredRunner
              );
            };
            microvm = {
              type = "app";
              program = toString (
                self.nixosConfigurations.microvm.config.microvm.declaredRunner
              );
            };
          } else { });

          # Checks for CI
          checks = {
            # Go tests
            go-test = pkgs.runCommand "go-test"
              {
                nativeBuildInputs = [ pkgs.go ];
                src = self;
              } ''
              export HOME=$TMPDIR
              export GOCACHE=$TMPDIR/go-cache
              cd $src
              go test -v ./...
              touch $out
            '';

            # Go lint
            go-lint = pkgs.runCommand "go-lint"
              {
                nativeBuildInputs = [ pkgs.go pkgs.golangci-lint ];
                src = self;
              } ''
              export HOME=$TMPDIR
              export GOCACHE=$TMPDIR/go-cache
              export GOLANGCI_LINT_CACHE=$TMPDIR/lint-cache
              cd $src
              golangci-lint run ./...
              touch $out
            '';

            # Nix formatting
            nix-fmt = pkgs.runCommand "nix-fmt"
              {
                nativeBuildInputs = [ pkgs.nixpkgs-fmt ];
                src = self;
              } ''
              nixpkgs-fmt --check $src/*.nix $src/nix/*.nix $src/nix/lib/*.nix $src/nix/verify/*.nix
              touch $out
            '';
          };
        }
      ) // {
      # NixOS configurations (system-independent)
      # MicroVM variants: docker (lowest resources), k3s (recommended), minikube (most compatible)
      nixosConfigurations = {
        # Docker variant: Direct Docker Compose (4GB RAM, 2 vCPUs)
        microvm-docker = nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          modules = [
            microvm.nixosModules.microvm
            (import ./nix/microvm { variant = "docker"; })
          ];
          specialArgs = {
            inherit self;
            k8sManifestsPath = ./k8s;
          };
        };

        # K3s variant: Lightweight Kubernetes (6GB RAM, 3 vCPUs) - Recommended
        microvm-k3s = nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          modules = [
            microvm.nixosModules.microvm
            (import ./nix/microvm { variant = "k3s"; })
          ];
          specialArgs = {
            inherit self;
            k8sManifestsPath = ./k8s;
          };
        };

        # Minikube variant: Full Minikube (8GB RAM, 4 vCPUs)
        microvm-minikube = nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          modules = [
            microvm.nixosModules.microvm
            (import ./nix/microvm { variant = "minikube"; })
          ];
          specialArgs = {
            inherit self;
            k8sManifestsPath = ./k8s;
          };
        };

        # Legacy alias (points to minikube for backwards compatibility)
        microvm = nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          modules = [
            microvm.nixosModules.microvm
            (import ./nix/microvm { variant = "minikube"; })
          ];
          specialArgs = {
            inherit self;
            k8sManifestsPath = ./k8s;
          };
        };
      };

      # NixOS modules for testing framework
      nixosModules = {
        microvm-docker = import ./nix/microvm { variant = "docker"; };
        microvm-k3s = import ./nix/microvm { variant = "k3s"; };
        microvm-minikube = import ./nix/microvm { variant = "minikube"; };
      };
    };
}
