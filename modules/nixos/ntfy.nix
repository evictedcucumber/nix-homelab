# ntfy in a container, which delivers Grafana's alerts to the phone. Only Grafana's container
# reaches it in plain HTTP, and the host's network gets it over TLS, on an address of its own.
# It has no way out, so Apple's push relay is out of reach and iOS only gets delayed delivery.
{
  config,
  lib,
  ...
}:
let
  endpoint = import ./ntfy-endpoint.nix;
  inherit (endpoint)
    address
    httpPort
    httpsPort
    topic
    ;
  inherit (config.ntfy) lanAddress;
  privateRanges = "{ 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 }";
  writer = "grafana";
  reader = "phone";
  credentials = [
    "ntfy-grafana-password"
    "ntfy-phone-password"
  ];
in
{
  options.ntfy.lanAddress = lib.mkOption {
    type = lib.types.nullOr lib.types.str;
    default = null;
    example = "172.16.0.5";
    description = "Address on the host's network to reach ntfy on. The host must also have it on an interface. Null leaves ntfy unreachable from outside.";
  };

  config = lib.mkMerge [
    {
      # The container gets them as system credentials, because its dynamic UID range hides
      # who owns a file on the host.
      sops.secrets = lib.genAttrs credentials (_: {
        restartUnits = [ "container@ntfy.service" ];
      });

      containers.ntfy = {
        localAddress = address;
        extraFlags = map (id: "--load-credential=${id}:${config.sops.secrets.${id}.path}") credentials;
        config =
          { config, pkgs, ... }:
          let
            cfg = config.services.ntfy-sh;
            tlsCert = "/var/lib/ntfy-sh/tls.crt";
            tlsKey = "/var/lib/ntfy-sh/tls.key";
            openssl = lib.getExe pkgs.openssl;
            ntfy = lib.getExe cfg.package;
            configFile = config.environment.etc."ntfy/server.yml".source;
            checkAddress = if lanAddress != null then lanAddress else address;
          in
          {
            containerFirewall.allowFrom.grafana = [ httpPort ];
            networking.firewall.allowedTCPPorts = [ httpsPort ];

            services.ntfy-sh = {
              enable = true;
              settings = {
                base-url =
                  if lanAddress != null then "https://${lanAddress}" else "http://${address}:${toString httpPort}";
                listen-http = "${address}:${toString httpPort}";
                listen-https = "${address}:${toString httpsPort}";
                cert-file = tlsCert;
                key-file = tlsKey;
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
                ImportCredential = credentials;
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

              # Needs a certificate to listen on HTTPS, and doesn't make one.
              preStart = ''
                umask 077

                # Made again when it's about to expire, or the host's address changes.
                certificate_valid() {
                  [ -s ${tlsKey} ] &&
                    ${openssl} x509 -in ${tlsCert} -noout -checkend 2592000 > /dev/null &&
                    ${openssl} x509 -in ${tlsCert} -noout -checkip ${checkAddress} > /dev/null
                }
                if ! certificate_valid; then
                  ${openssl} req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 3650 \
                    -subj /CN=ntfy -keyout ${tlsKey} -out ${tlsCert} \
                    -addext basicConstraints=critical,CA:FALSE -addext keyUsage=digitalSignature \
                    -addext extendedKeyUsage=serverAuth \
                    -addext "subjectAltName=DNS:ntfy,DNS:localhost,IP:127.0.0.1,IP:${address}${
                      lib.optionalString (lanAddress != null) ",IP:${lanAddress}"
                    }"
                fi
              '';
            };
          };
      };

      # A clean exit inside the container counts as success, so on-failure wouldn't restart it.
      systemd.services."container@ntfy" = {
        startLimitIntervalSec = 0;
        serviceConfig = {
          Restart = lib.mkForce "always";
          RestartSec = 5;
        };
      };
    }

    (lib.mkIf (lanAddress != null) {
      assertions = [
        {
          assertion = lib.any (interface: lib.any (a: a.address == lanAddress) interface.ipv4.addresses) (
            lib.attrValues config.networking.interfaces
          );
          message = "ntfy.lanAddress ${lanAddress} must also be set on one of the host's interfaces.";
        }
      ];

      # The drop keeps the host's own services, such as SSH, off this address. The output chain
      # covers the host itself, whose traffic to its own address skips prerouting.
      networking.nftables.tables.ntfy-dnat = {
        family = "ip";
        content = ''
          chain prerouting {
            type nat hook prerouting priority dstnat; policy accept;

            iifname != "lo" iifname != "ve-*" ip daddr ${lanAddress} ip saddr ${privateRanges} tcp dport 443 dnat to ${address}:${toString httpsPort}
          }

          chain output {
            type nat hook output priority dstnat; policy accept;

            ip daddr ${lanAddress} tcp dport 443 dnat to ${address}:${toString httpsPort}
          }

          chain input {
            type filter hook input priority filter - 1; policy accept;

            # ntfy's replies to the host come back on ve-ntfy.
            iifname != "lo" ct state != { established, related } ip daddr ${lanAddress} drop
          }
        '';
      };
    })
  ];
}
