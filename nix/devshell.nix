{ pkgs }:

pkgs.mkShell {
  name = "clickhouse-otel-dev";

  nativeBuildInputs = with pkgs; [
    # Go development
    go_1_26
    gopls
    golangci-lint
    delve
    go-tools # staticcheck, etc.

    # Nix tools
    nil # Nix LSP
    nixpkgs-fmt
    nix-prefetch-git
    nix-prefetch-github

    # Kubernetes tools
    kubectl
    minikube
    kubernetes-helm
    k9s
    stern # Multi-pod log tailing

    # Container tools
    docker
    docker-compose
    skopeo
    dive # Container image analysis

    # Database tools
    clickhouse # CLI client

    # General utilities
    jq
    yq-go
    curl
    httpie
    watchexec # File watcher

    # Documentation
    mdbook
  ];

  shellHook = ''
    echo "========================================"
    echo "ClickHouse OTel Pipeline Dev Environment"
    echo "========================================"
    echo ""
    echo "Go version: $(go version)"
    echo ""
    echo "Build commands:"
    echo "  nix build .#loggen           - Build Go application"
    echo "  nix build .#loggen-image     - Build Go container"
    echo "  nix build .#all-images       - Build all container images"
    echo ""
    echo "Test commands:"
    echo "  go test ./...                - Run Go tests"
    echo "  go test -race ./...          - Run Go race tests"
    echo "  nix flake check              - Run all checks"
    echo ""
    echo "Run commands:"
    echo "  nix run .#loggen             - Run the log generator"
    echo "  nix run .#load-images        - Load images into Docker"
    echo ""
    echo "Development:"
    echo "  go run ./cmd/loggen          - Run locally"
    echo "  watchexec -e go 'go test ./...' - Watch and test"
    echo ""
    echo "Verify commands:"
    echo "  nix run .#verify-loggen         - Check Go app emitting logs"
    echo "  nix run .#verify-fluentbit      - Check FluentBit processing"
    echo "  nix run .#verify-fluentbit-output - Check FluentBit -> ClickHouse"
    echo "  nix run .#verify-clickhouse     - Check logs in ClickHouse"
    echo "  nix run .#verify-hyperdx        - Check HyperDX operational"
    echo "  nix run .#verify-pipeline       - Run all checks"
    echo ""
    echo "Failure injection (for testing):"
    echo "  nix run .#break-<component>     - Inject failure"
    echo "  nix run .#fix-<component>       - Restore component"
    echo "  nix run .#test-verify-scripts   - Run full test suite"
    echo ""
    echo "Latency measurement:"
    echo "  nix run .#measure-latency       - Passive: analyze age of recent logs"
    echo "  nix run .#measure-latency-active - Active: wait for new logs and measure"
    echo ""

    # Set Go environment
    export GOPATH="$HOME/go"
    export PATH="$GOPATH/bin:$PATH"

    # Development defaults
    export LOGGEN_MAX_NUMBER="100"
    export LOGGEN_NUM_STRINGS="10"
    export LOGGEN_SLEEP_DURATION="5s"
    export LOGGEN_HEALTH_PORT="8081"
  '';

  # Environment variables
  LOGGEN_MAX_NUMBER = "100";
  LOGGEN_NUM_STRINGS = "10";
  LOGGEN_SLEEP_DURATION = "5s";
}
