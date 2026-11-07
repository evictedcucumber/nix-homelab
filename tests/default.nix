{
  pkgs,
  blocklist,
  hostModules,
  sops-nix,
}:
let
  specialArgs = { inherit blocklist; };
  # For modules that take secrets, which the hosts' real keys can't decrypt in a VM.
  secrets.imports = [
    sops-nix.nixosModules.sops
    ./secrets
  ];
in
builtins.mapAttrs
  (
    _: module:
    pkgs.testers.runNixOSTest {
      imports = [ module ];
      # Containers restart forever, so a broken one would otherwise never fail its test.
      globalTimeout = 300;
    }
  )
  {
    container-isolation = {
      imports = [ ./nspawn/container-isolation.nix ];
      defaults = secrets;
    };
    logging = {
      imports = [ ./nspawn/logging.nix ];
      defaults = secrets;
    };
    ntfy = {
      imports = [ ./nspawn/ntfy.nix ];
      node = { inherit specialArgs; };
      defaults = secrets;
    };
    pihole = {
      imports = [ ./nspawn/pihole.nix ];
      node = { inherit specialArgs; };
      defaults = secrets;
    };
    nix-signing = ./nix-signing.nix;
    boot = {
      imports = [ ./boot.nix ];
      node = { inherit specialArgs; };
      nodes.machine.imports = hostModules "dcyclops";
      defaults.imports = [
        ./secrets
        ./secrets/users.nix
      ];
    };
  }
