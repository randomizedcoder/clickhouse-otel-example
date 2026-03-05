# OpenTelemetry Collector
#
# Two build strategies are provided:
#
# 1. `ocb` - The OCB builder tool (Nix-built, works)
# 2. `image` - Pre-built Docker image with locked digest (practical)
#
# Building the full collector from source is complex because OCB generates
# Go code that needs `go mod download` (network access). Options:
#   a) Use __noChroot (impure but works)
#   b) Pre-generate and commit the Go module
#   c) Use the official image with locked digest (reproducible enough)
#
# We provide option (c) for now with the OCB tool for future improvements.
{ lib
, buildGoModule
, fetchFromGitHub
, dockerTools
}:

let
  version = "0.147.0";
  imageVersion = "0.96.0"; # Stable version for image

  # OCB - OpenTelemetry Collector Builder (Nix-built)
  ocb = buildGoModule rec {
    pname = "ocb";
    inherit version;

    src = fetchFromGitHub {
      owner = "open-telemetry";
      repo = "opentelemetry-collector";
      rev = "cmd/builder/v${version}";
      hash = "sha256-aiMCMmEmiV0DzEF+Ot/ph55CkR9RuKW08PJGjWbGtPM=";
    };

    sourceRoot = "source/cmd/builder";
    vendorHash = "sha256-XFgG9WMokxo45Cnpz44XiuwLzYKC1NnVis2lK0r9fks=";
    ldflags = [ "-s" "-w" ];
    doCheck = false;

    meta = with lib; {
      description = "OpenTelemetry Collector Builder (OCB)";
      homepage = "https://github.com/open-telemetry/opentelemetry-collector";
      license = licenses.asl20;
      mainProgram = "builder";
    };
  };

  # Pre-built image with locked digest (reproducible)
  # To update: docker pull otel/opentelemetry-collector-contrib:VERSION
  #            docker inspect --format='{{index .RepoDigests 0}}' IMAGE
  image = dockerTools.pullImage {
    imageName = "otel/opentelemetry-collector-contrib";
    imageDigest = "sha256:7ef2a2ff46b9e432321fdd63df104bfeedaf7b4e276950f42c634d0f23521fc4";
    sha256 = "sha256-vz5UvJ8hLeVDayBYZM30FCdtetkjQeZ2BZOq/nsVNHI=";
    finalImageName = "otel-collector";
    finalImageTag = imageVersion;
  };

in
{
  inherit ocb image version;

  # Default package is OCB (the builder tool)
  package = ocb;
}
