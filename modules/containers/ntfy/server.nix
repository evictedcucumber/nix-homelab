# The ntfy server inside its container, with the users it accepts and its TLS certificate.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  endpoint = import ./endpoint.nix;
  inherit (endpoint) httpPort httpsPort topic;
  inherit (config.container) address lanAddress;
  cfg = config.services.ntfy-sh;
  ntfy = lib.getExe cfg.package;
  configFile = config.environment.etc."ntfy/server.yml".source;
  writer = "grafana";
  reader = "phone";
in
{
  container.tls = {
    service = "ntfy-sh";
    directory = "/var/lib/ntfy-sh";
  };

  containerFirewall.allowFrom.grafana = [ httpPort ];
  networking.firewall.allowedTCPPorts = [ httpsPort ];

  services.ntfy-sh = {
    enable = true;
    settings = {
      base-url =
        if lanAddress != null then "https://${lanAddress}" else "http://${address}:${toString httpPort}";
      listen-http = "${address}:${toString httpPort}";
      listen-https = "${address}:${toString httpsPort}";
      cert-file = config.container.tls.certFile;
      key-file = config.container.tls.keyFile;
      # Nobody gets in without an entry below. The users come in at start, with their hashes.
      auth-default-access = "deny-all";
      auth-access = [
        "${writer}:${topic}:wo"
        "${reader}:${topic}:ro"
      ];
      # Alerts are text, and a phone offline for a day or two should still catch up.
      attachment-cache-dir = "";
      cache-duration = "72h";
      web-root = "disable";
    };
  };

  systemd.services.ntfy-sh = {
    # A stuck failure retries slowly instead of looping hot.
    startLimitIntervalSec = 300;
    startLimitBurst = 20;
    serviceConfig = {
      ImportCredential = config.container.credentials;
      Restart = "on-failure";
      RestartSec = 5;
      # The nixpkgs command, with the users in the environment so their hashes stay out
      # of the Nix store.
      ExecStart = lib.mkForce (
        pkgs.writeShellScript "ntfy-start" ''
          set -eu
          shopt -s inherit_errexit

          password_hash() {
            local password
            password=$(< "$CREDENTIALS_DIRECTORY/$1") || exit 1
            # A user with no password could be logged into by anyone, so stop instead.
            [ -n "$password" ] || { echo "empty $1" >&2; exit 1; }
            local hashed
            hashed=$(printf '%s\n%s\n' "$password" "$password" | ${ntfy} user hash 2> /dev/null) || exit 1
            case $hashed in
              '$2'*) printf %s "$hashed" ;;
              *) echo "could not hash $1" >&2; exit 1 ;;
            esac
          }

          writer_hash=$(password_hash ntfy-grafana-password)
          reader_hash=$(password_hash ntfy-phone-password)
          export NTFY_AUTH_USERS="${writer}:$writer_hash:user,${reader}:$reader_hash:user"
          exec ${ntfy} serve -c ${configFile}
        ''
      );
    };
  };
}
