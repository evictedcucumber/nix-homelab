# Pi-hole in a container, with DNS and its web interface on an address of its own on the host's
# network. It resolves through the host, so its lookups still leave over TLS.
{
  config,
  lib,
  blocklist,
  ...
}:
let
  address = "10.233.0.2";
  # Only this file, not the rest of the repo, ends up on the host.
  blocklistFile = builtins.path {
    name = "blocklist.txt";
    path = "${blocklist}/lists/all_domains.txt";
  };
  inherit (config.pihole) lanAddress;
  privateRanges = "{ 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 }";
  credential = "pihole-web-password";
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
      # The container gets it as a system credential, because its dynamic UID range hides
      # who owns a file on the host.
      sops.secrets.${credential}.restartUnits = [ "container@pihole.service" ];

      containers.pihole = {
        localAddress = address;
        extraFlags = [ "--load-credential=${credential}:${config.sops.secrets.${credential}.path}" ];
        config =
          { config, pkgs, ... }:
          let
            cfg = config.services.pihole-ftl;
          in
          {
            containerFirewall.allowDns = true;

            environment.etc."pihole/blocklist.txt".source = blocklistFile;

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
              # Lists are added by URL, so a store path would leave a stale entry after each update.
              lists = [
                {
                  url = "file:///etc/pihole/blocklist.txt";
                  description = "Pi-hole Optimized Blocklists";
                }
              ];
              # Can't be downloaded, and only labels devices in DHCP and the network table.
              macvendorURL = "";
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

            # Nixpkgs rotates these by date only, and pihole.log gets a line per query.
            services.logrotate.settings = {
              pihole-dnsmasq.maxsize = "100M";
              pihole-ftl.maxsize = "50M";
            };

            # As a oneshot this holds up the container's boot, but it needs DNS, and the host only
            # sets up its side of the network after boot. Lists also fail to load while DNS is down.
            systemd.services.pihole-ftl-setup = {
              startLimitIntervalSec = 0;
              serviceConfig = {
                Type = lib.mkForce "exec";
                Restart = "on-failure";
                RestartSec = 30;
              };
            };

            systemd.services.pihole-ftl = {
              startLimitIntervalSec = 0;
              # Starting FTL also reloads the lists.
              restartTriggers = [ blocklistFile ];
              serviceConfig = {
                Restart = lib.mkForce "always";
                # The host passes it in as a system credential, which stays out of the Nix store.
                ImportCredential = credential;
                # The nixpkgs command, with the password in FTL's environment. That also makes it
                # win over the one in an existing pihole.toml on every start.
                ExecStart = lib.mkForce (
                  pkgs.writeShellScript "pihole-ftl-start" ''
                    set -eu
                    password=$(< "$CREDENTIALS_DIRECTORY/${credential}")
                    # FTL runs without a password if this is empty, so stop instead.
                    [ -n "$password" ]
                    export FTLCONF_webserver_api_password=$password
                    exec ${lib.getExe cfg.package} no-daemon
                  ''
                );
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
