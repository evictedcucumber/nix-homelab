# Default deny in, out and forward. Only inbound SSH, which the openssh module opens, and
# outbound NTP, NTS key exchange and DNS over TLS are allowed. Deploys are pushed from the
# control node over SSH. The host can also connect to its containers, whose own firewalls
# decide.
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

            oifname { "lo", "ve-*" } accept
            ct state { established, related } accept
            udp dport 123 accept
            tcp dport 4460 accept
            ip daddr { ${lib.concatStringsSep ", " dnsServers} } tcp dport 853 accept
          }
        '';
      };
      # Limits new SSH connections per address. Runs before the firewall, because
      # extraInputRules comes after its SSH accept.
      tables.ssh-limit = {
        family = "inet";
        content = ''
          set new_connections {
            type ipv4_addr
            flags dynamic, timeout
            timeout 5m
          }

          chain input {
            type filter hook input priority filter - 1; policy accept;

            tcp dport 22 ct state new add @new_connections { ip saddr limit rate over 30/minute } drop
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
