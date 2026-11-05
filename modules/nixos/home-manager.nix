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

  # A read-only store still creates this directory, which a fresh install lacks.
  systemd.tmpfiles.rules = [ "d /nix/var/nix/temproots 0755 root root -" ];

  # Activation checks it can reach the Nix store. V-268152 keeps riley off the daemon,
  # so every user opens the store read-only, without the daemon.
  systemd.services = lib.genAttrs (map (user: "home-manager-${user}") users) (_: {
    environment = {
      NIX_CONFIG = "extra-experimental-features = read-only-local-store";
      NIX_REMOTE = "local?read-only=true";
    };
  });
}
