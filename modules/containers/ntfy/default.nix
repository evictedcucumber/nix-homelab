# ntfy in a container, which delivers Grafana's alerts to the phone. Only Grafana's container
# reaches it in plain HTTP, and the host's network gets it over TLS, on an address of its own.
# It has no way out, so Apple's push relay is out of reach and iOS only gets delayed delivery.
let
  endpoint = import ./endpoint.nix;
in
{
  imports = [ ../framework ];

  containers.ntfy = {
    localAddress = endpoint.address;
    credentials = [
      "ntfy-grafana-password"
      "ntfy-phone-password"
    ];
    lan = {
      hostNumber = 5;
      ports = [
        {
          port = 443;
          to = endpoint.httpsPort;
        }
      ];
      fromHost = true;
    };

    config.imports = [
      ../guest/monitoring.nix
      ../guest/tls.nix
      ./server.nix
    ];
  };
}
