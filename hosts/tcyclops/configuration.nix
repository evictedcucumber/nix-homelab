{
  imports = [ ../../modules/nixos/hyperv.nix ];

  networking = {
    interfaces.eth0.ipv4.addresses = [
      {
        address = "10.0.4.2";
        prefixLength = 24;
      }
    ];
    defaultGateway = "10.0.4.1";
  };
}
