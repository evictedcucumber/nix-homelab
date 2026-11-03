{ config, pkgs, ... }:
let
  adminUser = "captain";
in
{
  time.timeZone = "Africa/Johannesburg";
  i18n.defaultLocale = "en_ZA.UTF-8";
  services.xserver.xkb.layout = "za";
  console.useXkbConfig = true;
  networking.timeServers = map (n: "${toString n}.za.pool.ntp.org") [
    0
    1
    2
    3
  ];

  nix = {
    settings = {
      experimental-features = [
        "nix-command"
        "flakes"
      ];
      auto-optimise-store = true;
      # Lets `nixos-rebuild --target-host` copy locally built, unsigned closures.
      trusted-users = [ "@wheel" ];
    };
    gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 30d";
    };
  };

  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "no";
    };
  };

  users.users.${adminUser} = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJGshhca+nI1Qt1zDNvHCYIokESlCHMi+0JjvcdW7+3F nix-homelab-control-node"
    ];
  };

  # The admin user has no password, so remote deploys can't answer a sudo prompt.
  security.sudo.wheelNeedsPassword = false;

  assertions = [
    {
      assertion = config.users.users.${adminUser}.openssh.authorizedKeys.keys != [ ];
      message = "Add an SSH public key for ${adminUser} in modules/nixos/common.nix: password and root SSH logins are disabled, so deploying without one locks you out.";
    }
  ];

  environment.systemPackages = [
    pkgs.git
    pkgs.htop
    pkgs.vim
  ];
}
