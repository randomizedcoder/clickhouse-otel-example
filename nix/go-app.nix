{ lib
, buildGoModule
, go_1_26
}:

let
  # Filter source to exclude non-Go directories
  # This prevents rebuilds when nix/, k8s/, or docs change
  goSourceFilter = name: type:
    let
      baseName = baseNameOf name;
      relPath = lib.removePrefix (toString ./.. + "/") name;
      # Exclude these directories entirely
      excludedDirs = [ "nix" "k8s" "docs" ".git" ".github" "result" ];
      isExcludedDir = builtins.any (d: lib.hasPrefix "${d}/" relPath || relPath == d) excludedDirs;
      # Exclude certain file types
      isExcludedFile = lib.hasSuffix ".md" baseName
                    || lib.hasSuffix ".yaml" baseName
                    || lib.hasSuffix ".yml" baseName
                    || lib.hasSuffix ".nix" baseName
                    || baseName == "flake.lock";
    in
    !isExcludedDir && !isExcludedFile;

  filteredSrc = lib.cleanSourceWith {
    src = ./..;
    filter = goSourceFilter;
    name = "loggen-source";
  };
in

buildGoModule.override { go = go_1_26; } rec {
  pname = "loggen";
  version = "0.1.0";

  # Use filtered source - excludes nix/, k8s/, docs/
  src = filteredSrc;

  # Vendor hash - set to null for local development
  # After first build, update this with the correct hash
  vendorHash = null;

  # Build configuration - disable CGO for static binary
  env.CGO_ENABLED = "0";

  ldflags = [
    "-s"
    "-w"
    "-X main.version=${version}"
  ];

  # Only build the loggen binary
  subPackages = [ "cmd/loggen" ];

  # Test configuration
  doCheck = true;
  checkFlags = [ "-v" ];

  meta = with lib; {
    description = "Log generator for OpenTelemetry pipeline demo";
    homepage = "https://github.com/randomizedcoder/clickhouse-otel-example";
    license = licenses.mit;
    maintainers = [ ];
    mainProgram = "loggen";
  };
}
