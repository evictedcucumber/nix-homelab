{
  imports = [
    ../../modules/nixos/hyperv.nix
    ../../modules/nixos/hyperv-lvm.nix
  ];

  lan.prefix = "172.16.0";
}
