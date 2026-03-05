# Redpanda - Kafka-compatible streaming platform
#
# Redpanda is a C++ project using the Seastar framework. Building from source
# requires significant effort (Seastar deps, C++20, etc.). We use the official
# Docker image with locked digest for reproducibility.
#
# To update:
#   docker pull docker.redpanda.com/redpandadata/redpanda:VERSION
#   docker inspect --format='{{index .RepoDigests 0}}' IMAGE
#   nix build .#redpanda.image (to get sha256)
{ lib
, dockerTools
}:

let
  version = "24.3.8";
  consoleVersion = "2.8.4";

  # Redpanda broker image
  redpandaImage = dockerTools.pullImage {
    imageName = "docker.redpanda.com/redpandadata/redpanda";
    imageDigest = "sha256:623a07b44f3b6508b327a4d18cdba8c9e7881dd9b3a362393e9a8df428c9294e";
    sha256 = "sha256-o/7PDG4TyWGazOccwcQGIaszNSQ+LRMxB2xDsA5kBcw=";
    finalImageName = "redpanda";
    finalImageTag = "v${version}";
  };

  # Redpanda Console image
  consoleImage = dockerTools.pullImage {
    imageName = "docker.redpanda.com/redpandadata/console";
    imageDigest = "sha256:5c4b20eb52e38971819a0cc76dceed328351a930b1b69f7b81e2ea91dcc2da45";
    sha256 = "sha256-2gcqH7t+u30WmM9c5d4AXHbjhbsSuVwh5TTpJSLJyMY=";
    finalImageName = "redpanda-console";
    finalImageTag = "v${consoleVersion}";
  };

in
{
  inherit version consoleVersion;

  # Redpanda broker
  image = redpandaImage;

  # Redpanda Console (web UI)
  inherit consoleImage;
}
