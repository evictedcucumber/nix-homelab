{
  imports = [
    ../../modules/nixos/hyperv.nix
    ../../modules/nixos/hyperv-lvm.nix
  ];

  networking = {
    interfaces.eth0.ipv4.addresses = [
      {
        address = "172.16.1.2";
        prefixLength = 24;
      }
      {
        address = "172.16.1.3";
        prefixLength = 24;
      }
      {
        address = "172.16.1.4";
        prefixLength = 24;
      }
      {
        address = "172.16.1.5";
        prefixLength = 24;
      }
    ];
    defaultGateway = "172.16.1.1";
  };

  containers.pihole.lan.address = "172.16.1.3";
  containers.grafana.lan.address = "172.16.1.4";
  containers.ntfy.lan.address = "172.16.1.5";
}
