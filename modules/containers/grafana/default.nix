# Grafana, Loki and Prometheus in one container, with Alloy on the host shipping its journal,
# which holds auth logs and audit records, and every monitored container's journal and metrics.
# Containers can't reach each other, and can't read the host's journal, so the three sit
# together and the shipper doesn't.
let
  endpoint = import ./endpoint.nix;
in
{
  imports = [
    ../framework
    ./alloy.nix
  ];

  containers.grafana = {
    localAddress = endpoint.address;
    credentials = [
      "grafana-admin-password"
      "grafana-secret-key"
      "ntfy-grafana-password"
    ];
    lan = {
      ports = [
        {
          port = 443;
          to = endpoint.grafanaPort;
        }
      ];
      fromHost = true;
    };

    config.imports = [
      ../guest/monitoring.nix
      ../guest/tls.nix
      ./alerting.nix
      ./grafana.nix
      ./loki.nix
      ./prometheus.nix
      ./rules.nix
    ];
  };
}
