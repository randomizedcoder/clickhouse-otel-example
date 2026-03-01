# nix/checks.nix
#
# CI checks for nix flake check.
# Runs go vet, tests, security scans, and validates Nix expressions.
#
# Lint Tiers:
#   - Tier 0 (Quick):         ~30s  - govet, errcheck, ineffassign, unused
#   - Tier 1 (Standard/CI):   ~2min - + gosec, gocritic, revive, staticcheck
#   - Tier 2 (Comprehensive): ~10min - + exhaustive, gocyclo, funlen, dupl, etc.
#
{ self, pkgs }:
let
  # Use Go 1.26 to match go.mod requirement
  go = pkgs.go_1_26;

  # Fetch Go modules (vendored dependencies)
  vendorHash = "sha256-xtC4Mj5CXkL3L0iO4aUYtM/0ohPb0eNc0W5U1uF/620=";

  # Create a derivation with vendored dependencies
  goModulesVendor = pkgs.stdenvNoCC.mkDerivation {
    name = "loggen-go-modules";
    nativeBuildInputs = [ go pkgs.cacert ];

    inherit (pkgs) system;

    outputHashAlgo = null;
    outputHashMode = "recursive";
    outputHash = vendorHash;

    src = self;

    GO111MODULE = "on";
    GOPROXY = "https://proxy.golang.org,direct";

    buildPhase = ''
      export HOME=$TMPDIR
      export GOCACHE=$TMPDIR/go-cache
      go mod download
    '';

    installPhase = ''
      go mod vendor
      cp -r vendor $out
    '';

    dontFixup = true;
  };

  # Common setup for Go checks
  setupGoWorkspace = ''
    export HOME=$TMPDIR
    export GOCACHE=$TMPDIR/go-cache
    export CGO_ENABLED=0

    # Create a proper workspace
    mkdir -p work
    cd work

    # Copy source (including dotfiles) and vendor directory
    cp -r $src/. .
    chmod -R u+w .
    rm -rf vendor
    cp -r $vendor vendor
    chmod -R u+w vendor
  '';

in
{
  # ─── Go Build ─────────────────────────────────────────────────────────────
  go-build = pkgs.runCommand "go-build"
    {
      nativeBuildInputs = [ go ];
      src = self;
      vendor = goModulesVendor;
    } ''
    ${setupGoWorkspace}
    go build -mod=vendor ./...
    touch $out
  '';

  # ─── Go Vet ───────────────────────────────────────────────────────────────
  go-vet = pkgs.runCommand "go-vet"
    {
      nativeBuildInputs = [ go ];
      src = self;
      vendor = goModulesVendor;
    } ''
    ${setupGoWorkspace}
    go vet -mod=vendor ./...
    touch $out
  '';

  # ─── Go Test ──────────────────────────────────────────────────────────────
  go-test = pkgs.runCommand "go-test"
    {
      nativeBuildInputs = [ go pkgs.gcc ];
      src = self;
      vendor = goModulesVendor;
    } ''
    ${setupGoWorkspace}
    go test -mod=vendor -v ./...
    touch $out
  '';

  # ─── Go Security Scan (gosec) ─────────────────────────────────────────────
  # Scan for common security issues in Go code
  # Excludes:
  #   G115 - integer overflow: false positives for validated conversions
  go-sec = pkgs.runCommand "go-sec"
    {
      nativeBuildInputs = [ go pkgs.gosec ];
      src = self;
      vendor = goModulesVendor;
    } ''
    ${setupGoWorkspace}
    gosec -exclude=G115 -fmt=text ./... > $out 2>&1 || {
      exitcode=$?
      cat $out
      # gosec returns 1 for findings, 2+ for errors
      exit $exitcode
    }
  '';

  # ─── Go Lint Tier 0 (Quick) ───────────────────────────────────────────────
  # Fast feedback: gofmt, goimports, govet, errcheck, ineffassign, unused
  # Time: ~30 seconds
  golangci-lint-quick = pkgs.runCommand "golangci-lint-quick"
    {
      nativeBuildInputs = [ go pkgs.golangci-lint ];
      src = self;
      vendor = goModulesVendor;
    } ''
    ${setupGoWorkspace}
    export GOLANGCI_LINT_CACHE=$TMPDIR/lint-cache
    golangci-lint run \
      --config .golangci-quick.yml \
      --timeout 60s \
      ./... > $out 2>&1 || (cat $out && exit 1)
  '';

  # ─── Go Lint Tier 1 (Standard - CI gating) ────────────────────────────────
  # PR validation: Tier 0 + gosec, gosimple, gocritic, revive, contextcheck
  # Time: ~2 minutes
  golangci-lint = pkgs.runCommand "golangci-lint"
    {
      nativeBuildInputs = [ go pkgs.golangci-lint ];
      src = self;
      vendor = goModulesVendor;
    } ''
    ${setupGoWorkspace}
    export GOLANGCI_LINT_CACHE=$TMPDIR/lint-cache
    golangci-lint run \
      --config .golangci.yml \
      --timeout 5m \
      ./... > $out 2>&1 || (cat $out && exit 1)
  '';

  # ─── Go Lint Tier 2 (Comprehensive - Nightly) ─────────────────────────────
  # Full analysis: Tier 1 + exhaustive, prealloc, gocyclo, funlen, goconst, dupl
  # Time: ~10 minutes
  golangci-lint-comprehensive = pkgs.runCommand "golangci-lint-comprehensive"
    {
      nativeBuildInputs = [ go pkgs.golangci-lint ];
      src = self;
      vendor = goModulesVendor;
    } ''
    ${setupGoWorkspace}
    export GOLANGCI_LINT_CACHE=$TMPDIR/lint-cache
    golangci-lint run \
      --config .golangci-comprehensive.yml \
      --timeout 15m \
      ./... > $out 2>&1 || (cat $out && exit 1)
  '';

  # ─── Nix Format Check ─────────────────────────────────────────────────────
  nix-fmt = pkgs.runCommand "nix-fmt"
    {
      nativeBuildInputs = [ pkgs.nixpkgs-fmt ];
      src = self;
    } ''
    nixpkgs-fmt --check $src/*.nix $src/nix/*.nix $src/nix/lib/*.nix $src/nix/verify/*.nix
    touch $out
  '';
}
