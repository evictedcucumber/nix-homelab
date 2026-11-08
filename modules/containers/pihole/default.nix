# Pi-hole in a container, with DNS and its web interface on an address of its own on the host's
# network. It resolves through the host, so its lookups still leave over TLS.
{ blocklist, ... }:
{
  imports = [ ../framework ];

  containers.pihole = {
    localAddress = "10.233.0.2";
    credentials = [ "pihole-web-password" ];
    lan.hostNumber = 3;
    lan.ports = [
      {
        port = 53;
        protocols = [
          "tcp"
          "udp"
        ];
      }
      { port = 80; }
      { port = 443; }
    ];

    # Only this file, not the rest of the repo, ends up on the host.
    specialArgs.blocklistFile = builtins.path {
      name = "blocklist.txt";
      path = "${blocklist}/lists/all_domains.txt";
    };

    config.imports = [
      ../guest/monitoring.nix
      ./ftl.nix
    ];
  };
}
