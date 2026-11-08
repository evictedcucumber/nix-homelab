# Reaching a container from the host's network, on an address of its own that the host
# forwards to the container. A host's lan.prefix and the container's hostNumber give the address,
# and the host puts it on its interface.
{ config, lib, ... }:
let
  host = config;
  withNumber = lib.filterAttrs (_: c: c.lan.hostNumber != null) config.containers;
  numbers = lib.mapAttrsToList (_: c: c.lan.hostNumber) withNumber;
  duplicates = lib.unique (lib.filter (n: lib.count (m: m == n) numbers > 1) numbers);

  privateRanges = "{ 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 }";

  exposed = lib.filterAttrs (_: c: c.lan.address != null) config.containers;

  match =
    p:
    if lib.length p.protocols == 1 then
      "${lib.head p.protocols} dport ${toString p.port}"
    else
      "meta l4proto { ${lib.concatStringsSep ", " p.protocols} } th dport ${toString p.port}";

  dnat =
    c: p:
    "${match p} dnat to ${c.localAddress}${lib.optionalString (p.to != null) ":${toString p.to}"}";

  prerouting =
    c:
    lib.concatMapStringsSep "\n" (
      p:
      ''iifname != "lo" iifname != "ve-*" ip daddr ${c.lan.address} ip saddr ${privateRanges} ${dnat c p}''
    ) c.lan.ports;

  output = c: lib.concatMapStringsSep "\n" (p: "ip daddr ${c.lan.address} ${dnat c p}") c.lan.ports;

  # The drop keeps the host's own services, such as SSH, off this address. The output chain
  # covers the host itself, whose traffic to its own address skips prerouting.
  table = name: c: {
    family = "ip";
    content = ''
      chain prerouting {
        type nat hook prerouting priority dstnat; policy accept;

        ${prerouting c}
      }

      ${lib.optionalString c.lan.fromHost ''
        chain output {
          type nat hook output priority dstnat; policy accept;

          ${output c}
        }
      ''}
      chain input {
        type filter hook input priority filter - 1; policy accept;

        ${lib.optionalString c.lan.fromHost "# Its replies to the host come back on ve-${name}."}
        iifname != "lo" ${lib.optionalString c.lan.fromHost "ct state != { established, related } "}ip daddr ${c.lan.address} drop
      }
    '';
  };
in
{
  imports = [ ../../nixos/lan.nix ];

  options.containers = lib.mkOption {
    type = lib.types.attrsOf (
      lib.types.submodule (
        { config, ... }:
        {
          options.lan = {
            hostNumber = lib.mkOption {
              type = lib.types.nullOr (lib.types.ints.between 1 254);
              default = null;
              example = 3;
              description = "Last octet of the address on the host's lan.prefix.";
            };

            address = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default =
                if host.lan.prefix != null && config.lan.hostNumber != null then
                  "${host.lan.prefix}.${toString config.lan.hostNumber}"
                else
                  null;
              defaultText = lib.literalExpression ''"''${config.lan.prefix}.''${hostNumber}" when both are set, else null'';
              example = "172.16.0.3";
              description = "Address on the host's network to reach the container on. Null leaves it unreachable from outside.";
            };

            ports = lib.mkOption {
              type = lib.types.listOf (
                lib.types.submodule {
                  options = {
                    port = lib.mkOption {
                      type = lib.types.port;
                      description = "Port on the address.";
                    };
                    to = lib.mkOption {
                      type = lib.types.nullOr lib.types.port;
                      default = null;
                      description = "Port in the container. Null for the same one.";
                    };
                    protocols = lib.mkOption {
                      type = lib.types.listOf (
                        lib.types.enum [
                          "tcp"
                          "udp"
                        ]
                      );
                      default = [ "tcp" ];
                      description = "Protocols to forward.";
                    };
                  };
                }
              );
              default = [ ];
              description = "What the address forwards to the container, and only to clients on private ranges.";
            };

            fromHost = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = "Let the host itself reach the container on the address too.";
            };
          };

          config.config.container.lanAddress = config.lan.address;
        }
      )
    );
  };

  config = lib.mkMerge [
    (lib.mkIf (config.lan.prefix != null) {
      networking.interfaces.${config.lan.interface}.ipv4.addresses = map (n: {
        address = "${config.lan.prefix}.${toString n}";
        prefixLength = 24;
      }) (lib.sort lib.lessThan numbers);

      assertions = [
        {
          assertion = duplicates == [ ];
          message = "Containers share lan.hostNumber ${lib.concatMapStringsSep ", " toString duplicates}.";
        }
        {
          assertion = !lib.any (n: n == config.lan.hostNumber || n == config.lan.gateway) numbers;
          message = "A container's lan.hostNumber is the host's own or the gateway's last octet (${toString config.lan.hostNumber}, ${toString config.lan.gateway}).";
        }
      ];
    })
    {
      assertions = lib.mapAttrsToList (name: c: {
        assertion = lib.any (interface: lib.any (a: a.address == c.lan.address) interface.ipv4.addresses) (
          lib.attrValues config.networking.interfaces
        );
        message = "containers.${name}.lan.address ${c.lan.address} must also be set on one of the host's interfaces.";
      }) exposed;

      networking.nftables.tables = lib.mapAttrs' (
        name: c: lib.nameValuePair "${name}-dnat" (table name c)
      ) exposed;
    }
  ];
}
