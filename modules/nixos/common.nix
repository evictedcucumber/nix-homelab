{ config, pkgs, ... }:
let
  adminUser = "captain";
in
{
  time.timeZone = "UTC";

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
    # Add your public key, e.g. "ssh-ed25519 AAAA... you@machine".
    openssh.authorizedKeys.keys = [ ];
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
