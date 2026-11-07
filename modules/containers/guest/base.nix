# Imported into every container. The options are what the host tells it, so a container's
# modules don't need the host's values, and the defaults every container shares.
{ lib, ... }:
{
  imports = [
    ./firewall.nix
    ../../nixos/log-retention.nix
    ../../nixos/minimal.nix
  ];

  options.container = {
    address = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      description = "The container's address, on its link to the host.";
    };
    lanAddress = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      readOnly = true;
      description = "The address the host's network reaches the container on, if any.";
    };
    credentials = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      readOnly = true;
      description = "Credentials the host loads into the container.";
    };
    hostName = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      description = "The host's name, not the container's.";
    };
    monitored = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Whether the host ships the container's journal. Set by importing monitoring.nix.";
    };
  };

  config.services.journald.settings.Journal.SystemMaxUse = "256M";
}
