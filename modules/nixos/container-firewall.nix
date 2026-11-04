# A container's own default-deny firewall, in and out, separate from the host's. Traffic
# has to pass both, so what the host allows stays blocked until the container allows it too.
{ config, lib, ... }:
let
  cfg = config.containerFirewall;
in
{
  options.containerFirewall = {
    allowDns = lib.mkEnableOption "DNS through the host, which also opens it on the host's firewall";

    extraOutputRules = lib.mkOption {
      type = lib.types.lines;
      default = "";
      example = "tcp dport 443 accept";
      description = "nftables rules for outbound connections, which the host must also forward.";
    };
  };

  config.networking = {
    firewall = {
      enable = true;
      allowPing = false;
      filterForward = true;
    };

    nftables = {
      enable = true;
      tables.egress = {
        family = "inet";
        content = ''
          chain output {
            type filter hook output priority filter; policy drop;

            oifname "lo" accept
            ct state { established, related } accept
            ${lib.optionalString cfg.allowDns ''
              ip daddr { ${lib.concatStringsSep ", " config.networking.nameservers} } meta l4proto { tcp, udp } th dport 53 accept
            ''}
            ${cfg.extraOutputRules}
          }
        '';
      };
    };
  };
}
