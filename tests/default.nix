{
  pkgs,
  blocklist,
  hostModules,
}:
let
  specialArgs = { inherit blocklist; };
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
    container-isolation = ./nspawn/container-isolation.nix;
    logging = ./nspawn/logging.nix;
    pihole = {
      imports = [ ./nspawn/pihole.nix ];
      node = { inherit specialArgs; };
    };
    nix-signing = ./nix-signing.nix;
    boot = {
      imports = [ ./boot.nix ];
      node = { inherit specialArgs; };
      nodes.machine.imports = hostModules "dcyclops";
    };
  }
