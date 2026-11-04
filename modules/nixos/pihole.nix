# Pi-hole in a container, with DNS and its web interface on an address of its own on the host's
# network. It resolves through the host, so its lookups still leave over TLS.
{ config, lib, ... }:
let
  address = "10.233.0.2";
  inherit (config.pihole) lanAddress;
  privateRanges = "{ 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 }";
in
{
  options.pihole.lanAddress = lib.mkOption {
    type = lib.types.nullOr lib.types.str;
    default = null;
    example = "172.16.0.3";
    description = "Address on the host's network to reach Pi-hole on. The host must also have it on an interface. Null leaves Pi-hole unreachable from outside.";
  };

  config = lib.mkMerge [
    {
      containers.pihole = {
        localAddress = address;
        config =
          { config, pkgs, ... }:
          let
            cfg = config.services.pihole-ftl;
            passwordFile = "${cfg.stateDirectory}/web-password.env";
          in
          {
            containerFirewall.allowDns = true;

            services.pihole-web = {
              enable = true;
              # The port 80 redirect goes here, and clients might not resolve through Pi-hole.
              hostName = lib.mkIf (lanAddress != null) lanAddress;
              ports = [
                "80r"
                "443s"
              ];
            };

            services.pihole-ftl = {
              enable = true;
              openFirewallDNS = true;
              openFirewallWebserver = true;
              settings = {
                dns = {
                  upstreams = config.networking.nameservers;
                  # The default refuses clients outside its own subnet. The host limits who gets here.
                  listeningMode = "ALL";
                  # Otherwise pi.hole answers the container's address, which clients can't reach.
                  reply.host = lib.mkIf (lanAddress != null) {
                    force4 = true;
                    IPv4 = lanAddress;
                  };
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
              serviceConfig = {
                Restart = lib.mkForce "always";
                # Made below, and kept out of the Nix store.
                EnvironmentFile = "-${passwordFile}";
              };
              preStart =
                let
                  gravity = cfg.settings.files.gravity;
                in
                ''
                  # Only made when downloading lists. FTL logs an error every second without it.
                  if [ ! -e ${gravity} ]; then
                    ${lib.getExe cfg.package} sqlite3 -ni ${gravity} < ${cfg.piholePackage}/share/pihole/advanced/Templates/gravity.db.sql
                    ${lib.getExe cfg.package} sqlite3 -ni ${gravity} "INSERT INTO info VALUES ('updated', 0), ('gravity_count', 0), ('antigravity_count', 0);"
                  fi
                  # FTL runs without a password if this is empty, so stop instead.
                  if [ ! -s ${passwordFile} ]; then
                    password=$(${pkgs.coreutils}/bin/head -c 18 /dev/urandom | ${pkgs.coreutils}/bin/base64)
                    [ -n "$password" ]
                    (umask 077; echo "FTLCONF_webserver_api_password=$password" > ${passwordFile})
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
    }

    (lib.mkIf (lanAddress != null) {
      assertions = [
        {
          assertion = lib.any (interface: lib.any (a: a.address == lanAddress) interface.ipv4.addresses) (
            lib.attrValues config.networking.interfaces
          );
          message = "pihole.lanAddress ${lanAddress} must also be set on one of the host's interfaces.";
        }
      ];

      # The drop keeps the host's own services, such as SSH, off this address.
      networking.nftables.tables.pihole-dnat = {
        family = "ip";
        content = ''
          chain prerouting {
            type nat hook prerouting priority dstnat; policy accept;

            iifname != "lo" iifname != "ve-*" ip daddr ${lanAddress} ip saddr ${privateRanges} meta l4proto { tcp, udp } th dport 53 dnat to ${address}
            iifname != "lo" iifname != "ve-*" ip daddr ${lanAddress} ip saddr ${privateRanges} tcp dport { 80, 443 } dnat to ${address}
          }

          chain input {
            type filter hook input priority filter - 1; policy accept;

            iifname != "lo" ip daddr ${lanAddress} drop
          }
        '';
      };
    })
  ];
}
