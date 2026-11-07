# Prometheus inside the Grafana container, receiving the host's metrics from Alloy.
let
  inherit (import ./endpoint.nix) prometheusPort;
in
{
  networking.firewall.allowedTCPPorts = [ prometheusPort ];

  services.prometheus = {
    enable = true;
    listenAddress = "0.0.0.0";
    port = prometheusPort;
    retentionTime = "30d";
    extraFlags = [ "--web.enable-remote-write-receiver" ];
  };
}
