# Throwaway desktop for testing services on dcyclops's network. Root logs in by itself and
# has no password, so this must never be deployed anywhere it can be reached.
{ dcyclops, pkgs, ... }:
{
  imports = [
    ../../modules/nixos/hyperv.nix
    ../../modules/nixos/lan.nix
  ];

  disko.devices.disk.main.content.partitions.root = {
    size = "100%";
    content = {
      type = "filesystem";
      format = "ext4";
      mountpoint = "/";
    };
  };

  lan = {
    inherit (dcyclops.lan) prefix;
    hostNumber = 254;
  };
  networking.nameservers = [ dcyclops.containers.pihole.lan.address ];

  users.users.root.hashedPassword = "";

  # `nix shell nixpkgs#<package>`, with nixpkgs pinned to this flake's version.
  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

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

  # Copied rather than linked, so it can be edited on the VM.
  systemd.tmpfiles.rules = [
    "d /root/tests/dns"
    "C /root/tests/dns/queries.txt 0644 - - - ${../../tests/dns/queries.txt}"
  ];

  environment.systemPackages = [
    pkgs.curl
    pkgs.dnsutils
  ];
}
