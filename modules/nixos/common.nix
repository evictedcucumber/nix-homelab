{ config, pkgs, ... }:
let
  adminUser = "captain";
  # Only set when a user is created. Change it after first boot, see the README.
  defaultPassword = "PleaseChangeMe1";
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

  networking.domain = "homelab.zezura.cc";

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
    uid = 1000;
    group = adminUser;
    extraGroups = [ "wheel" ];
    initialPassword = defaultPassword;
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJGshhca+nI1Qt1zDNvHCYIokESlCHMi+0JjvcdW7+3F nix-homelab-control-node"
    ];
  };

  users.users.riley = {
    isNormalUser = true;
    uid = 2000;
    group = "riley";
    initialPassword = defaultPassword;
  };

  users.groups = {
    ${adminUser}.gid = 1000;
    riley.gid = 2000;
  };

  # NixOS needs a root account, so lock it instead. Passwords here are mutable, so
  # locking it has to happen on every activation to catch one set by a manual install.
  system.activationScripts.lockRoot = {
    deps = [ "users" ];
    text = "${pkgs.shadow}/bin/passwd --lock root >/dev/null";
  };

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
