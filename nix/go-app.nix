{ lib
, buildGoModule
, go_1_26
}:

buildGoModule.override { go = go_1_26; } rec {
  pname = "loggen";
  version = "0.1.0";

  # Use the local source
  src = ./..;

  # Vendor hash - set to null for local development
  # After first build, update this with the correct hash
  vendorHash = "sha256-+9nnwhPZJexWQZz+oUGeXRf9CLkJbT9E8vi9K4U6iE0=";

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
