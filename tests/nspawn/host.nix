# A test container acting as a host, so its own containers are nested.
{ lib, ... }:
{
  imports = [
    ../../modules/containers/framework
    ../../modules/nixos/firewall.nix
  ];

  # The Nix sandbox has too few UIDs to give a nested container its own range. This also drops
  # the assertions, but `just test` still evaluates them by building the real hosts.
  options.containers = lib.mkOption {
    type = lib.types.attrsOf (lib.types.submodule { config.privateUsers = lib.mkForce "no"; });
  };

  config = {
    assertions = lib.mkForce [ ];
    networking.domain = "test";
    # nixos-container binds these into its containers, and a test container doesn't have them.
    systemd.tmpfiles.rules = [
      "d /nix/var/nix/db 0755 root root -"
      "d /nix/var/nix/daemon-socket 0755 root root -"
    ];
  };
}
