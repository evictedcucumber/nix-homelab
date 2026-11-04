# Default deny in, out and forward. Only inbound SSH, which the openssh module opens, and
# outbound NTP, NTS key exchange and DNS over TLS are allowed. Deploys are pushed from WSL
# over SSH.
{ lib, ... }:
let
  dnsServers = map (u: u.address) (import ./dns-upstreams.nix);
in
{
  networking = {
    # The firewall always accepts ICMPv6 and DHCPv6, and IPv6 can't work without outbound NDP.
    enableIPv6 = false;

    nftables = {
      enable = true;
      tables.egress = {
        family = "inet";
        content = ''
          chain output {
            type filter hook output priority filter; policy drop;

            oifname "lo" accept
            ct state { established, related } accept
            udp dport 123 accept
            tcp dport 4460 accept
            ip daddr { ${lib.concatStringsSep ", " dnsServers} } tcp dport 853 accept
          }
        '';
      };
    };

    firewall = {
      allowPing = false;
      filterForward = true;
    };
  };
}
