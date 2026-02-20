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
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          config.allowUnfree = true;
        };

        # Go application package
        goApp = pkgs.callPackage ./nix/go-app.nix { };

        # FluentBit package with our configuration
        fluentbit = pkgs.callPackage ./nix/fluentbit.nix {
          inherit (pkgs) fluent-bit;
        };

        # HyperDX package (uses Yarn Berry v4)
        hyperdx = pkgs.callPackage ./nix/hyperdx.nix {
          inherit (pkgs) yarn-berry inter ibm-plex roboto roboto-mono;
        };

        # Container images
        containers = pkgs.callPackage ./nix/containers.nix {
          inherit goApp fluentbit hyperdx;
        };

      in
      {
        # Packages
        packages = {
          # Go application binary
          loggen = goApp;

          # FluentBit binary
          fluentbit = fluentbit;

          # HyperDX
          hyperdx = hyperdx;

          # OCI container images
          loggen-image = containers.loggenImage;
          fluentbit-image = containers.fluentbitImage;
          clickhouse-image = containers.clickhouseImage;
          hyperdx-image = containers.hyperdxImage;

          # All images bundled
          all-images = containers.allImages;

          # Default package
          default = goApp;
        };

        # Development shell
        devShells.default = pkgs.callPackage ./nix/devshell.nix { };

        # Apps for running
        apps = {
          loggen = {
            type = "app";
            program = "${goApp}/bin/loggen";
          };

          # Run all tests
          test = {
            type = "app";
            program = toString (pkgs.writeShellScript "test" ''
              set -e
              cd ${self}
              ${pkgs.go}/bin/go test -v ./...
            '');
          };

          # Run race tests
          test-race = {
            type = "app";
            program = toString (pkgs.writeShellScript "test-race" ''
              set -e
              cd ${self}
              CGO_ENABLED=1 ${pkgs.go}/bin/go test -race -v ./...
            '');
          };

          # Load images into docker
          load-images = {
            type = "app";
            program = "${containers.loadScript}";
          };
        };

        # Checks for CI
        checks = {
          # Go tests
          go-test = pkgs.runCommand "go-test" {
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
          go-lint = pkgs.runCommand "go-lint" {
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
          nix-fmt = pkgs.runCommand "nix-fmt" {
            nativeBuildInputs = [ pkgs.nixpkgs-fmt ];
            src = self;
          } ''
            nixpkgs-fmt --check $src/*.nix $src/nix/*.nix
            touch $out
          '';
        };
      }
    ) // {
      # NixOS configurations (system-independent)
      nixosConfigurations.microvm = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          microvm.nixosModules.microvm
          ./nix/microvm.nix
        ];
        specialArgs = {
          inherit self;
          flake-inputs = { inherit nixpkgs microvm; };
        };
      };
    };
}
