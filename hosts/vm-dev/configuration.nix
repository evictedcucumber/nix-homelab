# Throwaway desktop for testing services on dcyclops's network. Root logs in by itself and
# has no password, so this must never be deployed anywhere it can be reached.
{ pkgs, ... }:
{
  imports = [ ../../modules/nixos/hyperv.nix ];

  networking = {
    interfaces.eth0.ipv4.addresses = [
      {
        address = "172.16.1.254";
        prefixLength = 24;
      }
    ];
    defaultGateway = "172.16.1.1";
    nameservers = [ "172.16.1.3" ];
  };

  users.users.root.hashedPassword = "";

  # LightDM's autologin refuses root, so a console login starts the desktop instead.
  services.getty.autologinUser = "root";
  environment.loginShellInit = ''
    if [ "$(tty)" = /dev/tty1 ]; then exec startxfce4; fi
  '';

  services.xserver = {
    enable = true;
    desktopManager.xfce = {
      enable = true;
      enableScreensaver = false;
    };
    displayManager.startx.enable = true;
  };

  # DNS over HTTPS would bypass Pi-hole.
  programs.firefox = {
    enable = true;
    policies.DNSOverHTTPS = {
      Enabled = false;
      Locked = true;
    };
  };

  environment.systemPackages = [
    pkgs.curl
    pkgs.dnsutils
  ];
}
