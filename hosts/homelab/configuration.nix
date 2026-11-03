{ ... }:
{
  networking.hostName = "homelab";
  time.timeZone = "UTC";

  services.openssh.enable = true;

  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  system.stateVersion = "24.11";
}
