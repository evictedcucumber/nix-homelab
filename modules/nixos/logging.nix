# Grafana and Loki in one container, with Alloy on the host shipping its journal, which holds
# auth logs and audit records, to Loki. Containers can't reach each other, and can't read the
# host's journal, so the two sit together and the shipper doesn't.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  address = "10.233.0.3";
  grafanaPort = 3000;
  lokiPort = 3100;
  # Outside the range NixOS hands out to system users, and unused in ids.nix.
  alloyUid = 399;
  inherit (config.logging) lanAddress;
  privateRanges = "{ 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 }";

  dashboards = pkgs.writeTextDir "host-logs.json" (builtins.readFile ./logging-dashboard.json);

  alloyConfig = ''
    loki.relabel "journal" {
      forward_to = []

      rule {
        source_labels = ["__journal__systemd_unit"]
        target_label  = "unit"
      }
      // One scope per login would make a label value per login.
      rule {
        source_labels = ["__journal__systemd_unit"]
        regex         = "session-[0-9]+\\.scope"
        target_label  = "unit"
        replacement   = "session.scope"
      }
      rule {
        source_labels = ["__journal_syslog_identifier"]
        target_label  = "identifier"
      }
      rule {
        source_labels = ["__journal__transport"]
        target_label  = "transport"
      }
      rule {
        source_labels = ["__journal_priority_keyword"]
        target_label  = "level"
      }
      // Set to the component's name, which says nothing.
      rule {
        action = "labeldrop"
        regex  = "job"
      }
    }

    loki.source.journal "host" {
      forward_to    = [loki.write.logging.receiver]
      relabel_rules = loki.relabel.journal.rules
      labels        = { host = ${builtins.toJSON config.networking.hostName} }
      max_age       = "72h"
    }

    loki.write "logging" {
      endpoint {
        url                 = "http://${address}:${toString lokiPort}/loki/api/v1/push"
        // Zero retries forever. The default gives up on a batch after about 8 minutes.
        max_backoff_retries = 0
        max_backoff_period  = "30s"
      }
    }
  '';
in
{
  options.logging.lanAddress = lib.mkOption {
    type = lib.types.nullOr lib.types.str;
    default = null;
    example = "172.16.0.4";
    description = "Address on the host's network to reach Grafana on. The host must also have it on an interface. Null leaves Grafana unreachable from outside.";
  };

  config = lib.mkMerge [
    {
      containers.logging = {
        localAddress = address;
        config =
          { config, pkgs, ... }:
          let
            cfg = config.services.grafana;
            tlsCert = "${cfg.dataDir}/tls.crt";
            tlsKey = "${cfg.dataDir}/tls.key";
            secretKeyFile = "${cfg.dataDir}/secret-key";
            passwordFile = "${cfg.dataDir}/admin-password";
            openssl = lib.getExe pkgs.openssl;
            checkAddress = if lanAddress != null then lanAddress else address;
          in
          {
            networking.firewall.allowedTCPPorts = [
              grafanaPort
              lokiPort
            ];

            services.loki = {
              enable = true;
              configuration = {
                auth_enabled = false;
                server = {
                  http_listen_address = "0.0.0.0";
                  http_listen_port = lokiPort;
                  grpc_listen_address = "127.0.0.1";
                  grpc_listen_port = 9096;
                };
                common = {
                  instance_addr = "127.0.0.1";
                  path_prefix = config.services.loki.dataDir;
                  storage.filesystem = {
                    chunks_directory = "${config.services.loki.dataDir}/chunks";
                    rules_directory = "${config.services.loki.dataDir}/rules";
                  };
                  replication_factor = 1;
                  ring.kvstore.store = "inmemory";
                };
                schema_config.configs = [
                  {
                    from = "2024-04-01";
                    store = "tsdb";
                    object_store = "filesystem";
                    schema = "v13";
                    index = {
                      prefix = "index_";
                      period = "24h";
                    };
                  }
                ];
                storage_config.tsdb_shipper = {
                  active_index_directory = "${config.services.loki.dataDir}/tsdb-index";
                  cache_location = "${config.services.loki.dataDir}/tsdb-cache";
                };
                ingester.wal.dir = "${config.services.loki.dataDir}/wal";
                compactor = {
                  working_directory = "${config.services.loki.dataDir}/compactor";
                  retention_enabled = true;
                  delete_request_store = "filesystem";
                };
                # Only age limits it. There's no cap on size.
                limits_config.retention_period = "720h";
                analytics.reporting_enabled = false;
              };
            };

            services.grafana = {
              enable = true;
              # Loki isn't bundled with Grafana 13, and the container can't download it.
              declarativePlugins = [ pkgs.grafanaPlugins.loki ];
              settings = {
                server = {
                  protocol = "https";
                  http_addr = "0.0.0.0";
                  http_port = grafanaPort;
                  cert_file = tlsCert;
                  cert_key = tlsKey;
                }
                // lib.optionalAttrs (lanAddress != null) {
                  domain = lanAddress;
                  root_url = "https://${lanAddress}/";
                };
                # Made below, and kept out of the Nix store.
                security = {
                  secret_key = "$__file{${secretKeyFile}}";
                  admin_password = "$__file{${passwordFile}}";
                  cookie_secure = true;
                  disable_gravatar = true;
                };
                users.allow_sign_up = false;
                "auth.anonymous".enabled = false;
                analytics = {
                  reporting_enabled = false;
                  check_for_updates = false;
                  check_for_plugin_updates = false;
                };
                news.news_feed_enabled = false;
              };

              provision = {
                datasources.settings = {
                  apiVersion = 1;
                  datasources = [
                    {
                      name = "Loki";
                      uid = "loki";
                      type = "loki";
                      access = "proxy";
                      url = "http://127.0.0.1:${toString lokiPort}";
                      isDefault = true;
                      editable = false;
                    }
                  ];
                };
                dashboards.settings = {
                  apiVersion = 1;
                  providers = [
                    {
                      name = "logging";
                      type = "file";
                      disableDeletion = true;
                      allowUiUpdates = false;
                      options.path = dashboards;
                    }
                  ];
                };
              };
            };

            # Grafana needs a certificate to start, and doesn't make one.
            systemd.services.grafana.preStart = ''
              umask 077
              for file in ${secretKeyFile} ${passwordFile}; do
                if [ ! -s "$file" ]; then
                  value=$(${openssl} rand -hex 24)
                  printf %s "$value" > "$file"
                fi
              done

              # Made again when it's about to expire, or the host's address changes.
              certificate_valid() {
                [ -s ${tlsKey} ] &&
                  ${openssl} x509 -in ${tlsCert} -noout -checkend 2592000 > /dev/null &&
                  ${openssl} x509 -in ${tlsCert} -noout -checkip ${checkAddress} > /dev/null
              }
              if ! certificate_valid; then
                ${openssl} req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 3650 \
                  -subj /CN=logging -keyout ${tlsKey} -out ${tlsCert} \
                  -addext "subjectAltName=DNS:logging,DNS:localhost,IP:127.0.0.1,IP:${address}${
                    lib.optionalString (lanAddress != null) ",IP:${lanAddress}"
                  }"
              fi
            '';
          };
      };

      # A clean exit inside the container counts as success, so on-failure wouldn't restart it.
      systemd.services."container@logging" = {
        startLimitIntervalSec = 0;
        serviceConfig = {
          Restart = lib.mkForce "always";
          RestartSec = 5;
        };
      };

      users = {
        users.alloy = {
          isSystemUser = true;
          uid = alloyUid;
          group = "alloy";
        };
        groups.alloy.gid = alloyUid;
      };

      services.alloy = {
        enable = true;
        # Its state, which holds the journal position, is in /var/lib/alloy.
        extraFlags = [
          "--storage.path=/var/lib/alloy"
          "--disable-reporting"
        ];
      };

      environment.etc."alloy/config.alloy".text = alloyConfig;

      systemd.services.alloy.serviceConfig = {
        # A fixed UID for the guard below, which a dynamic user wouldn't have.
        DynamicUser = lib.mkForce false;
        User = "alloy";
        Group = "alloy";
        # What DynamicUser implied.
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectHome = true;
        ProtectSystem = "strict";
        RestrictSUIDSGID = true;
      };

      # Loki has no authentication, so keep other users on the host from reading the logs.
      networking.nftables.tables.logging-guard = {
        family = "ip";
        content = ''
          chain output {
            type filter hook output priority filter - 1; policy accept;

            ip daddr ${address} tcp dport ${toString lokiPort} meta skuid != { 0, ${toString alloyUid} } drop
          }
        '';
      };
    }

    (lib.mkIf (lanAddress != null) {
      assertions = [
        {
          assertion = lib.any (interface: lib.any (a: a.address == lanAddress) interface.ipv4.addresses) (
            lib.attrValues config.networking.interfaces
          );
          message = "logging.lanAddress ${lanAddress} must also be set on one of the host's interfaces.";
        }
      ];

      # The drop keeps the host's own services, such as SSH, off this address.
      networking.nftables.tables.logging-dnat = {
        family = "ip";
        content = ''
          chain prerouting {
            type nat hook prerouting priority dstnat; policy accept;

            iifname != "lo" iifname != "ve-*" ip daddr ${lanAddress} ip saddr ${privateRanges} tcp dport 443 dnat to ${address}:${toString grafanaPort}
          }

          chain input {
            type filter hook input priority filter - 1; policy accept;

            iifname != "lo" ip daddr ${lanAddress} drop
          }
        '';
      };
    })
  ];
}
