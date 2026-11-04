{
  imports = [ ../../modules/nixos/hyperv.nix ];

  networking = {
    interfaces.eth0.ipv4.addresses = [
      {
        address = "172.16.1.2";
        prefixLength = 24;
      }
    ];
    defaultGateway = "172.16.1.1";
  };
}
