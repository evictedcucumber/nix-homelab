{
  imports = [
    ../../modules/nixos/hyperv.nix
    ../../modules/nixos/hyperv-lvm.nix
  ];

  networking = {
    interfaces.eth0.ipv4.addresses = [
      {
        address = "172.16.0.2";
        prefixLength = 24;
      }
      {
        address = "172.16.0.3";
        prefixLength = 24;
      }
      {
        address = "172.16.0.4";
        prefixLength = 24;
      }
    ];
    defaultGateway = "172.16.0.1";
  };

  pihole.lanAddress = "172.16.0.3";
  logging.lanAddress = "172.16.0.4";
}
