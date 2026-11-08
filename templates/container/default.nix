# Copy to modules/containers/<name>/ and replace `example`, then import the directory from
# modules/containers/default.nix. A container's name is also its hostname and state directory.
{
  # The host's side: the framework every container shares.
  imports = [ ../framework ];

  containers.example = {
    # Unused, in 10.233.0.0/24 and not .1, which is the host's.
    localAddress = "10.233.0.10";

    # Sops secrets, loaded into the container under the same names. Read them from
    # $CREDENTIALS_DIRECTORY, after importing them in the service's ImportCredential.
    # credentials = [ "example-password" ];

    # To reach it from the host's network, give it a last octet and forward ports to it.
    # A host with a lan.prefix gets the address on its interface by itself.
    # lan = {
    #   hostNumber = 6;
    #   ports = [
    #     {
    #       port = 443;
    #       to = 8443;
    #     }
    #   ];
    #   # Lets the host itself use the address too.
    #   fromHost = true;
    # };

    # The container's own configuration, from the guest modules and its service.
    config =
      { config, ... }:
      {
        imports = [
          # Has the host's Alloy ship this container's journal.
          ../guest/monitoring.nix
          # A self-signed certificate for a service that needs one to start.
          # ../guest/tls.nix
        ];

        # Other containers, by name, that may connect to these ports.
        # containerFirewall.allowFrom.grafana = [ 8080 ];
        # Needs the host's DNS, which also opens it on the host's firewall.
        # containerFirewall.allowDns = true;

        # config.container.address and config.container.lanAddress give the container's own
        # addresses to the service's settings.
        services.nginx = {
          enable = true;
          virtualHosts.${config.networking.hostName}.listen = [
            {
              addr = config.container.address;
              port = 80;
            }
          ];
        };
        networking.firewall.allowedTCPPorts = [ 80 ];
      };
  };
}
