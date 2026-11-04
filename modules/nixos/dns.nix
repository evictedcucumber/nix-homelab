# resolved answers local lookups and forwards them to dnsdist, which sends them over TLS to
# the first healthy upstream. Unlike resolved alone, it goes back to Cloudflare on recovery.
{ lib, ... }:
let
  listen = {
    address = "127.0.0.1";
    port = 5300;
  };

  mkServer = order: upstream: ''
    newServer({
      address = "${upstream.address}:853",
      tls = "openssl",
      subjectName = "${upstream.name}",
      validateCertificates = true,
      caStore = "/etc/ssl/certs/ca-certificates.crt",
      order = ${toString order},
      checkInterval = 10,
      maxCheckFailures = 2,
    })
  '';
in
{
  networking.nameservers = [ "${listen.address}:${toString listen.port}" ];

  services.resolved = {
    enable = true;
    settings.Resolve = {
      # Sends every lookup to dnsdist, not to any server learned from DHCP.
      Domains = [ "~." ];
      FallbackDNS = [ ];
    };
  };

  services.dnsdist = {
    enable = true;
    listenAddress = listen.address;
    listenPort = listen.port;
    extraConfig = ''
      -- Its version check is a plain lookup of a PowerDNS name.
      setSecurityPollSuffix("")
      setServerPolicy(firstAvailable)
      ${lib.concatStrings (lib.imap1 mkServer (import ./dns-upstreams.nix))}
    '';
  };
}
