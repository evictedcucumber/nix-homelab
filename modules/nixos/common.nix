{
  config,
  lib,
  ...
}:
let
  adminUser = "captain";
  # Hashes are public, so the check stops a weak scheme and a missing file.
  hashFile = name: ../../users + "/${name}.hash";
  passwordHash =
    name:
    let
      file = hashFile name;
    in
    if builtins.pathExists file then lib.trim (builtins.readFile file) else null;
  badLogins =
    lib.filter
      (
        name:
        let
          hash = config.users.users.${name}.hashedPassword;
        in
        hash == null || !lib.hasPrefix "$y$" hash
      )
      [
        adminUser
        "riley"
      ];
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

  # Each generation keeps a kernel and initrd on the small ESP.
  boot.loader.systemd-boot.configurationLimit = lib.mkDefault 10;

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
    hashedPassword = passwordHash adminUser;
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJGshhca+nI1Qt1zDNvHCYIokESlCHMi+0JjvcdW7+3F nix-homelab-control-node"
    ];
  };

  users.users.riley = {
    isNormalUser = true;
    uid = 2000;
    group = "riley";
    hashedPassword = passwordHash "riley";
  };

  users.groups = {
    ${adminUser}.gid = 1000;
    riley.gid = 2000;
  };

  users.mutableUsers = false;
  # NixOS needs a root account, so lock it.
  users.users.root.hashedPassword = "!";

  assertions = [
    {
      assertion = badLogins == [ ];
      message = "Login passwords are yescrypt hashes in users/<name>.hash, and these are missing or aren't ($y$): ${
        lib.concatMapStringsSep ", " (name: "run 'just set-password ${name}'") badLogins
      }.";
    }
    {
      assertion = config.users.users.${adminUser}.openssh.authorizedKeys.keys != [ ];
      message = "Add an SSH public key for ${adminUser} in modules/nixos/common.nix: password and root SSH logins are disabled, so deploying without one locks you out.";
    }
  ];
}
