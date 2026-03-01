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

          # Minikube lifecycle management
          minikube = import ./nix/minikube.nix {
            inherit pkgs;
            lib = pkgs.lib;
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

            # Go development apps (using writeShellApplication for shellcheck)
            build = {
              type = "app";
              program = "${pkgs.writeShellApplication {
                name = "build";
                runtimeInputs = [ pkgs.go_1_26 ];
                text = ''
                  cd ${self}
                  go build -v ./...
                '';
              }}/bin/build";
            };

            test = {
              type = "app";
              program = "${pkgs.writeShellApplication {
                name = "test";
                runtimeInputs = [ pkgs.go_1_26 ];
                text = ''
                  cd ${self}
                  go test -v ./...
                '';
              }}/bin/test";
            };

            test-race = {
              type = "app";
              program = "${pkgs.writeShellApplication {
                name = "test-race";
                runtimeInputs = [ pkgs.go_1_26 ];
                text = ''
                  cd ${self}
                  CGO_ENABLED=1 go test -race -v ./...
                '';
              }}/bin/test-race";
            };

            vet = {
              type = "app";
              program = "${pkgs.writeShellApplication {
                name = "vet";
                runtimeInputs = [ pkgs.go_1_26 ];
                text = ''
                  cd ${self}
                  go vet ./...
                '';
              }}/bin/vet";
            };

            # Tiered linting (quick -> standard -> comprehensive)
            lint-quick = {
              type = "app";
              program = "${pkgs.writeShellApplication {
                name = "lint-quick";
                runtimeInputs = [ pkgs.go_1_26 pkgs.golangci-lint ];
                text = ''
                  cd ${self}
                  golangci-lint run --config .golangci-quick.yml --timeout 60s ./...
                '';
              }}/bin/lint-quick";
            };

            lint = {
              type = "app";
              program = "${pkgs.writeShellApplication {
                name = "lint";
                runtimeInputs = [ pkgs.go_1_26 pkgs.golangci-lint ];
                text = ''
                  cd ${self}
                  golangci-lint run --config .golangci.yml --timeout 5m ./...
                '';
              }}/bin/lint";
            };

            lint-comprehensive = {
              type = "app";
              program = "${pkgs.writeShellApplication {
                name = "lint-comprehensive";
                runtimeInputs = [ pkgs.go_1_26 pkgs.golangci-lint ];
                text = ''
                  cd ${self}
                  golangci-lint run --config .golangci-comprehensive.yml --timeout 15m ./...
                '';
              }}/bin/lint-comprehensive";
            };

            # Security scanning
            sec = {
              type = "app";
              program = "${pkgs.writeShellApplication {
                name = "sec";
                runtimeInputs = [ pkgs.go_1_26 pkgs.gosec ];
                text = ''
                  cd ${self}
                  gosec -exclude=G115 -fmt=text ./...
                '';
              }}/bin/sec";
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

            compose-force-stop = {
              type = "app";
              program = "${compose.composeForceStop}/bin/compose-force-stop";
            };

            # Minikube lifecycle apps
            minikube-up = {
              type = "app";
              program = "${minikube.minikubeUp}/bin/minikube-up";
            };

            minikube-status = {
              type = "app";
              program = "${minikube.minikubeStatus}/bin/minikube-status";
            };

            minikube-logs = {
              type = "app";
              program = "${minikube.minikubeLogs}/bin/minikube-logs";
            };

            minikube-down = {
              type = "app";
              program = "${minikube.minikubeDown}/bin/minikube-down";
            };

            minikube-delete = {
              type = "app";
              program = "${minikube.minikubeDelete}/bin/minikube-delete";
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

            # MicroVM help - show usage instructions after VM starts
            microvm-help = {
              type = "app";
              program = "${pkgs.writeShellApplication {
                name = "microvm-help";
                text = ''
                  echo ""
                  echo "=============================================="
                  echo "  OTel Demo Stack (MicroVM + K3s)"
                  echo "=============================================="
                  echo ""
                  echo "ACCESS POINTS:"
                  echo "  HyperDX UI:      http://localhost:30808"
                  echo "  HyperDX API:     http://localhost:30800"
                  echo "  ClickHouse HTTP: http://localhost:28123"
                  echo "  SSH:             ssh -p 22022 demo@localhost  (password: demo)"
                  echo ""
                  echo "VIEW LOGGEN LOGS:"
                  echo "  # From host (via SSH)"
                  echo "  ssh -p 22022 demo@localhost 'sudo k3s kubectl -n otel-demo logs -f deployment/loggen'"
                  echo ""
                  echo "  # Inside VM"
                  echo "  sudo k3s kubectl -n otel-demo logs -f deployment/loggen"
                  echo ""
                  echo "QUERY CLICKHOUSE:"
                  echo "  # From host (via HTTP API)"
                  echo "  curl 'http://localhost:28123/?query=SELECT+count()+FROM+otel_logs'"
                  echo ""
                  echo "  # From host (via SSH)"
                  echo "  ssh -p 22022 demo@localhost 'sudo k3s kubectl -n otel-demo exec -it sts/clickhouse -- \\"
                  echo "    clickhouse-client --query \"SELECT count() FROM otel_logs\"'"
                  echo ""
                  echo "  # Inside VM - Interactive CLI"
                  echo "  sudo k3s kubectl -n otel-demo exec -it sts/clickhouse -- clickhouse-client"
                  echo ""
                  echo "  # View recent logs"
                  echo "  curl 'http://localhost:28123/?query=SELECT+*+FROM+otel_logs+ORDER+BY+Timestamp+DESC+LIMIT+5+FORMAT+Pretty'"
                  echo ""
                  echo "CHECK POD STATUS:"
                  echo "  # From host"
                  echo "  ssh -p 22022 demo@localhost 'sudo k3s kubectl -n otel-demo get pods'"
                  echo ""
                  echo "  # Inside VM"
                  echo "  sudo k3s kubectl -n otel-demo get pods"
                  echo ""
                  echo "LIFECYCLE COMMANDS:"
                  echo "  nix run .#microvm-status  - Check VM and pod status"
                  echo "  nix run .#microvm-stop    - Graceful shutdown"
                  echo "  nix run .#stop-vm         - Force kill VM process"
                  echo "  nix run .#clean-vm        - Remove VM state files"
                  echo ""
                '';
              }}/bin/microvm-help";
            };

            # MicroVM status check
            microvm-status = {
              type = "app";
              program = "${pkgs.writeShellApplication {
                name = "microvm-status";
                runtimeInputs = [ pkgs.openssh pkgs.procps ];
                text = ''
                  echo "=== MicroVM Status ==="

                  if pgrep -f "qemu.*otel-demo" > /dev/null; then
                    echo "VM Process: RUNNING"

                    echo ""
                    echo "Checking SSH connectivity..."
                    if ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -p 22022 demo@localhost "echo 'SSH: OK'" 2>/dev/null; then
                      echo ""
                      echo "=== Pods inside VM ==="
                      ssh -p 22022 demo@localhost "sudo k3s kubectl -n otel-demo get pods 2>/dev/null || sudo kubectl -n otel-demo get pods 2>/dev/null" || echo "(kubectl not accessible)"
                    else
                      echo "SSH: NOT READY (VM still booting?)"
                    fi
                  else
                    echo "VM Process: NOT RUNNING"
                    exit 1
                  fi
                '';
              }}/bin/microvm-status";
            };

            # MicroVM graceful shutdown
            microvm-stop = {
              type = "app";
              program = "${pkgs.writeShellApplication {
                name = "microvm-stop";
                runtimeInputs = [ pkgs.openssh pkgs.procps ];
                text = ''
                  echo "=== Graceful MicroVM Shutdown ==="

                  if ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -p 22022 root@localhost "poweroff" 2>/dev/null; then
                    echo "Shutdown command sent. Waiting for VM to stop..."
                    sleep 5

                    if pgrep -f "qemu.*otel-demo" > /dev/null; then
                      echo "VM still running. Use 'nix run .#stop-vm' to force kill."
                    else
                      echo "VM stopped gracefully."
                    fi
                  else
                    echo "Could not connect to VM. It may not be running."
                    echo "Use 'nix run .#stop-vm' to force kill any orphaned processes."
                  fi
                '';
              }}/bin/microvm-stop";
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
