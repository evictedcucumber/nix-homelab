# Pi-hole in a container, answering plain DNS on port 53 of the host's addresses. It resolves
# through the host, so its lookups still leave over TLS.
{ lib, ... }:
let
  address = "10.233.0.2";
in
{
  containers.pihole = {
    localAddress = address;
    config =
      { config, ... }:
      {
        containerFirewall.allowDns = true;

        services.pihole-ftl = {
          enable = true;
          openFirewallDNS = true;
          settings = {
            dns = {
              upstreams = config.networking.nameservers;
              # The default refuses clients outside its own subnet. The host limits who gets here.
              listeningMode = "ALL";
            };
            # On by default, and neither firewall allows it.
            ntp = {
              ipv4.active = false;
              ipv6.active = false;
              sync.active = false;
            };
          };
        };

        systemd.services.pihole-ftl = {
          startLimitIntervalSec = 0;
          serviceConfig.Restart = lib.mkForce "always";
          # Only made when downloading lists. FTL logs an error every second without it.
          preStart =
            let
              cfg = config.services.pihole-ftl;
              gravity = cfg.settings.files.gravity;
            in
            ''
              if [ ! -e ${gravity} ]; then
                ${lib.getExe cfg.package} sqlite3 -ni ${gravity} < ${cfg.piholePackage}/share/pihole/advanced/Templates/gravity.db.sql
              fi
            '';
        };
      };
  };

  # A clean exit inside the container counts as success, so on-failure wouldn't restart it.
  systemd.services."container@pihole" = {
    startLimitIntervalSec = 0;
    serviceConfig = {
      Restart = lib.mkForce "always";
      RestartSec = 5;
    };
  };

  # Not forwardPorts, which also catches other containers' lookups to the host's stub.
  networking.nftables.tables.pihole-dnat = {
    family = "ip";
    content = ''
      chain prerouting {
        type nat hook prerouting priority dstnat; policy accept;

        iifname != "lo" iifname != "ve-*" ip saddr { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 } fib daddr type local meta l4proto { tcp, udp } th dport 53 dnat to ${address}
      }
    '';
  };
}
