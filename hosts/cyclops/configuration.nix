{
  imports = [ ./hardware-configuration.nix ];

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = false;

  # Set to the NixOS release first installed on this host, then never change it.
  system.stateVersion = "26.11";
}
