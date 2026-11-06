{
  config,
  lib,
  pkgs,
  ...
}:
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
  networking.timeServers = [ "time.cloudflare.com" ];
  services.chrony = {
    enable = true;
    enableNTS = true;
    # rtcsync can't be used alongside this.
    enableRTCTrimming = false;
    makestep.threshold = 1.0;
    extraConfig = "rtcsync";
  };

  nix = {
    settings = {
      experimental-features = [
        "nix-command"
        "flakes"
      ];
      auto-optimise-store = true;
      # Only root is trusted, so a deploy must arrive signed with the key in keys/.
      trusted-users = [ "root" ];
      require-sigs = true;
      trusted-public-keys = [
        "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
        (lib.trim (builtins.readFile ../../keys/nix-homelab-signing.pub))
      ];
      # Hosts never build. WSL builds everything, and deploys push it here.
      max-jobs = 0;
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
    # Only keys set in this repo count, not ones added to ~/.ssh on the host.
    authorizedKeysInHomedir = false;
    hostKeys = [
      {
        type = "ed25519";
        path = "/etc/ssh/ssh_host_ed25519_key";
      }
    ];
    settings = {
      AuthenticationMethods = "publickey";
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "no";
      AllowUsers = [ adminUser ];
      MaxAuthTries = 3;
      LoginGraceTime = 30;
      AllowTcpForwarding = false;
      AllowAgentForwarding = false;
      AllowStreamLocalForwarding = false;
      PermitTunnel = false;
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
}
