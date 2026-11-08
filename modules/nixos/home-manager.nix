{ lib, ... }:
let
  users = [
    "captain"
    "riley"
  ];
in
{
  home-manager = {
    useGlobalPkgs = true;
    useUserPackages = true;
    # A file already in the way would otherwise fail activation, and the deploy with it.
    backupFileExtension = "hm-bak";
    sharedModules = [
      ../../home/common.nix
      # The system generation already keeps each home generation alive.
      { home.activationGenerateGcRoot = false; }
    ];
    users = lib.genAttrs users (user: ../../home/${user}.nix);
  };
}
