# The host's address on its LAN, from the /24 prefix each host sets once.
{ config, lib, ... }:
let
  cfg = config.lan;
in
{
  options.lan = {
    prefix = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "172.16.0";
      description = "First three octets of the host's /24 LAN. Null leaves the addresses to the host's own config.";
    };

    interface = lib.mkOption {
      type = lib.types.str;
      default = "eth0";
      description = "Interface on the LAN.";
    };

    hostNumber = lib.mkOption {
      type = lib.types.ints.between 1 254;
      default = 2;
      description = "Last octet of the host's own address.";
    };

    gateway = lib.mkOption {
      type = lib.types.ints.between 1 254;
      default = 1;
      description = "Last octet of the default gateway.";
    };
  };

  config = lib.mkIf (cfg.prefix != null) {
    networking.interfaces.${cfg.interface}.ipv4.addresses = lib.mkBefore [
      {
        address = "${cfg.prefix}.${toString cfg.hostNumber}";
        prefixLength = 24;
      }
    ];
    networking.defaultGateway = "${cfg.prefix}.${toString cfg.gateway}";
  };
}
