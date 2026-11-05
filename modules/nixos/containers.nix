# Defaults for `containers.<name>`. Each container only needs a `localAddress` and its `config`.
# A veth per container, not a bridge, so traffic between containers crosses the host's
# default-deny forward chain. Takes effect on a host once it declares a container.
{ config, lib, ... }:
let
  prefix = "10.233.0";
  subnet = "${prefix}.0/24";
  hostAddress = "${prefix}.1";

  containers = lib.attrValues config.containers;
  addresses = map (c: c.localAddress) containers;

  # Only a bare address: a CIDR one would give the container's interface a wider route.
  validAddress =
    a:
    let
      octet = if a == null then null else builtins.match "${lib.escapeRegex prefix}\\.([0-9]{1,3})" a;
    in
    octet != null && lib.toInt (lib.head octet) >= 2 && lib.toInt (lib.head octet) <= 254;

  dnsInterfaces = lib.pipe config.containers [
    (lib.filterAttrs (_: c: c.config.containerFirewall.allowDns))
    lib.attrNames
    (map (name: ''"ve-${name}"''))
  ];
in
{
  options.containers = lib.mkOption {
    type = lib.types.attrsOf (
      lib.types.submodule {
        config = {
          # Not defaults. Without these, the firewalls and guard below don't contain a container.
          privateNetwork = true;
          privateUsers = "pick";
          autoStart = lib.mkDefault true;
          inherit hostAddress;

          config = {
            imports = [
              ./container-firewall.nix
              ./log-retention.nix
              ./minimal.nix
            ];

            services.journald.settings.Journal.SystemMaxUse = "256M";

            networking = {
              enableIPv6 = false;
              nameservers = [ hostAddress ];
              # The host's resolv.conf points at its own loopback.
              useHostResolvConf = false;
            };

            system.stateVersion = lib.mkDefault config.system.stateVersion;
          };
        };
      }
    );
  };

  config = lib.mkIf (config.containers != { }) {
    assertions = [
      {
        assertion = lib.allUnique addresses && lib.all validAddress addresses;
        message = "Give each container in `containers` a unique localAddress in ${subnet}, other than ${hostAddress}.";
      }
      {
        assertion = lib.all (
          c:
          c.privateNetwork
          && c.privateUsers == "pick"
          && c.hostBridge == null
          && c.interfaces == [ ]
          && c.macvlans == [ ]
          && c.extraVeths == { }
          && c.additionalCapabilities == [ ]
          && !lib.any (lib.hasPrefix "--network-") c.extraFlags
          && !lib.any (lib.hasPrefix "--private-") c.extraFlags
          && !lib.any (lib.hasPrefix "--capability") c.extraFlags
        ) containers;
        message = "Containers keep their private network and user namespace, and only get their ve-<name> interface, because the host's rules don't cover anything else.";
      }
    ];

    boot.kernel.sysctl."net.ipv4.conf.all.forwarding" = 1;

    # Containers resolve through the host, so their lookups also leave over TLS. Root in a
    # container can flush its firewall, so the host only opens DNS to those that asked for it.
    # Container files keep their in-container UIDs on disk, which can match host users.
    systemd.tmpfiles.rules = [ "d /var/lib/nixos-containers 0700 root root -" ];

    services.resolved.settings.Resolve.DNSStubListenerExtra = hostAddress;
    networking.firewall.extraInputRules = lib.mkIf (dnsInterfaces != [ ]) ''
      iifname { ${lib.concatStringsSep ", " dnsInterfaces} } meta l4proto { tcp, udp } th dport 53 accept
    '';

    networking.nftables.tables.container-guard = {
      family = "inet";
      content = ''
        chain prerouting {
          type filter hook prerouting priority mangle; policy accept;

          # The firewall's reverse path check is loose, which lets a container forge sources.
          iifname "ve-*" fib saddr . iif oif missing drop
        }

        chain input {
          type filter hook input priority filter - 1; policy accept;

          # Runs before the firewall, which accepts SSH on every interface.
          iifname "ve-*" meta nfproto ipv6 drop
          iifname "ve-*" ct state != { established, related } ip daddr . meta l4proto . th dport != { ${hostAddress} . tcp . 53, ${hostAddress} . udp . 53 } drop
        }

        chain forward {
          type filter hook forward priority filter - 1; policy accept;

          # Runs before the firewall, which accepts anything DNATed by another container's forwardPorts.
          iifname "ve-*" meta nfproto ipv6 drop
          iifname "ve-*" oifname "ve-*" drop
        }
      '';
    };

    # Not networking.nat, which also accepts all forwarded traffic from these containers.
    networking.nftables.tables.container-nat = {
      family = "ip";
      content = ''
        chain postrouting {
          type nat hook postrouting priority srcnat; policy accept;

          ip saddr ${subnet} oifname != "ve-*" masquerade
        }
      '';
    };
  };
}
