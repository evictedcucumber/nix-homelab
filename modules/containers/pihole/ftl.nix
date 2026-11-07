# FTL, its web interface and its logs inside the Pi-hole container.
{
  config,
  lib,
  pkgs,
  blocklistFile,
  ...
}:
let
  cfg = config.services.pihole-ftl;
  inherit (config.container) lanAddress;
  credential = "pihole-web-password";
in
{
  containerFirewall.allowDns = true;

  environment.etc."pihole/blocklist.txt".source = blocklistFile;

  services.pihole-web = {
    enable = true;
    # The port 80 redirect goes here, and clients might not resolve through Pi-hole.
    hostName = lib.mkIf (lanAddress != null) lanAddress;
    ports = [
      "80r"
      "443s"
    ];
  };

  services.pihole-ftl = {
    enable = true;
    openFirewallDNS = true;
    openFirewallWebserver = true;
    # Lists are added by URL, so a store path would leave a stale entry after each update.
    lists = [
      {
        url = "file:///etc/pihole/blocklist.txt";
        description = "Pi-hole Optimized Blocklists";
      }
    ];
    # Can't be downloaded, and only labels devices in DHCP and the network table.
    macvendorURL = "";
    settings = {
      dns = {
        upstreams = config.networking.nameservers;
        # The default refuses clients outside its own subnet. The host limits who gets here.
        listeningMode = "ALL";
        # Otherwise pi.hole answers the container's address, which clients can't reach.
        reply.host = lib.mkIf (lanAddress != null) {
          force4 = true;
          IPv4 = lanAddress;
        };
      };
      # On by default, and neither firewall allows it.
      ntp = {
        ipv4.active = false;
        ipv6.active = false;
        sync.active = false;
      };
    };
  };

  # Nixpkgs rotates these by date only, and pihole.log gets a line per query.
  services.logrotate.settings = {
    pihole-dnsmasq.maxsize = "100M";
    pihole-ftl.maxsize = "50M";
  };

  # As a oneshot this holds up the container's boot, but it needs DNS, and the host only
  # sets up its side of the network after boot. Lists also fail to load while DNS is down.
  systemd.services.pihole-ftl-setup = {
    startLimitIntervalSec = 0;
    serviceConfig = {
      Type = lib.mkForce "exec";
      Restart = "on-failure";
      RestartSec = 30;
    };
  };

  systemd.services.pihole-ftl = {
    startLimitIntervalSec = 0;
    # Starting FTL also reloads the lists.
    restartTriggers = [ blocklistFile ];
    serviceConfig = {
      Restart = lib.mkForce "always";
      # The host passes it in as a system credential, which stays out of the Nix store.
      ImportCredential = credential;
      # The nixpkgs command, with the password in FTL's environment. That also makes it
      # win over the one in an existing pihole.toml on every start.
      ExecStart = lib.mkForce (
        pkgs.writeShellScript "pihole-ftl-start" ''
          set -eu
          password=$(< "$CREDENTIALS_DIRECTORY/${credential}")
          # FTL runs without a password if this is empty, so stop instead.
          [ -n "$password" ]
          export FTLCONF_webserver_api_password=$password
          exec ${lib.getExe cfg.package} no-daemon
        ''
      );
    };
    preStart =
      let
        gravity = cfg.settings.files.gravity;
      in
      ''
        # Only made when downloading lists. FTL logs an error every second without it.
        if [ ! -e ${gravity} ]; then
          ${lib.getExe cfg.package} sqlite3 -ni ${gravity} < ${cfg.piholePackage}/share/pihole/advanced/Templates/gravity.db.sql
          ${lib.getExe cfg.package} sqlite3 -ni ${gravity} "INSERT INTO info VALUES ('updated', 0), ('gravity_count', 0), ('antigravity_count', 0);"
        fi
      '';
  };
}
