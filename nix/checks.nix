# CI checks extracted from flake.nix for maintainability
{ self, pkgs }:
{
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
}
