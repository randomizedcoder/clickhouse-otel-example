# Flake app helpers for DRY app definitions
{ lib }:
{
  # Create a simple app definition from a package
  # mkApp :: derivation -> string -> attrset
  mkApp = pkg: binName: {
    type = "app";
    program = "${pkg}/bin/${binName}";
  };

  # Create app definitions from a set of packages
  # Assumes each package has a binary with the same name as the attribute
  # mkApps :: attrset -> attrset
  mkApps = packages:
    lib.mapAttrs
      (name: pkg: {
        type = "app";
        program = "${pkg}/bin/${name}";
      })
      packages;

  # Create app definitions from a set of packages with custom binary names
  # mkAppsCustom :: attrset -> (string -> derivation -> string) -> attrset
  mkAppsCustom = packages: getBinName:
    lib.mapAttrs
      (name: pkg: {
        type = "app";
        program = "${pkg}/bin/${getBinName name pkg}";
      })
      packages;
}
