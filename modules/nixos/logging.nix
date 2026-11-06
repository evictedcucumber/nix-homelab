# Grafana, Loki and Prometheus in one container, with Alloy on the host shipping its journal,
# which holds auth logs and audit records, and every container's journal and metrics. Containers
# can't reach each other, and can't read the host's journal, so the three sit together and the
# shipper doesn't.
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
  prometheusPort = 9090;
  # Outside the range NixOS hands out to system users, and unused in ids.nix.
  alloyUid = 399;
  inherit (config.logging) lanAddress;
  privateRanges = "{ 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 }";
  ntfy = import ./ntfy-endpoint.nix;
  credentials = [
    "grafana-admin-password"
    "grafana-secret-key"
    "ntfy-grafana-password"
  ];

  dashboards = pkgs.symlinkJoin {
    name = "grafana-dashboards";
    paths = [
      (pkgs.writeTextDir "host-logs.json" (builtins.readFile ./logging-dashboard.json))
      (pkgs.writeTextDir "containers.json" (builtins.readFile ./containers-dashboard.json))
    ];
  };

  containerNames = lib.attrNames config.containers;
  # Component labels are identifiers, so other characters in a container's name become _.
  componentName = lib.stringAsChars (c: if builtins.match "[A-Za-z0-9_]" c != null then c else "_");
  hostName = builtins.toJSON config.networking.hostName;

  # The label comes from the config, never from the journal, whose fields the container controls.
  containerJournals = lib.concatMapStrings (name: ''
    loki.source.journal "container_${componentName name}" {
      forward_to    = [loki.write.logging.receiver]
      relabel_rules = loki.relabel.journal.rules
      path          = ${builtins.toJSON "/var/lib/nixos-containers/${name}/var/log/journal"}
      labels        = { host = ${hostName}, container = ${builtins.toJSON name} }
      max_age       = "72h"
    }

  '') containerNames;

  # The password is read from the credential when Grafana loads it, so it stays out of the store.
  ntfyContactPoint =
    credentialsDir:
    { name, query }:
    {
      inherit name;
      receivers = [
        {
          uid = name;
          type = "webhook";
          settings = {
            url = "http://${ntfy.address}:${toString ntfy.httpPort}/${ntfy.topic}?template=grafana${query}";
            httpMethod = "POST";
            username = "grafana";
            password = "$__file{${credentialsDir}/ntfy-grafana-password}";
            title = ''{{ template "ntfy.title" . }}'';
            message = ''{{ template "ntfy.message" . }}'';
          };
        }
      ];
    };

  # A rule whose query already returns 1 for a firing series and 0 for the rest.
  mkRule =
    {
      uid,
      title,
      expr,
      summary,
      severity ? "warning",
      duration ? "5m",
      noData ? "OK",
    }:
    let
      expression = refId: model: {
        inherit refId;
        datasourceUid = "__expr__";
        model = model // {
          inherit refId;
          datasource = {
            type = "__expr__";
            uid = "__expr__";
          };
        };
      };
    in
    {
      inherit uid title;
      condition = "C";
      "for" = duration;
      noDataState = noData;
      execErrState = "Error";
      labels = { inherit severity; };
      annotations = { inherit summary; };
      data = [
        {
          refId = "A";
          datasourceUid = "prometheus";
          relativeTimeRange = {
            from = 600;
            to = 0;
          };
          model = {
            refId = "A";
            inherit expr;
            instant = true;
            range = false;
            datasource = {
              type = "prometheus";
              uid = "prometheus";
            };
          };
        }
        (expression "B" {
          type = "reduce";
          expression = "A";
          reducer = "last";
          settings.mode = "dropNN";
        })
        (expression "C" {
          type = "threshold";
          expression = "B";
          conditions = [
            {
              evaluator = {
                type = "gt";
                params = [ 0 ];
              };
            }
          ];
        })
      ];
    };

  alertRules = [
    (mkRule {
      uid = "filesystem-full";
      title = "Filesystem almost full";
      expr = ''max by (host, mountpoint) ((1 - node_filesystem_avail_bytes{fstype!~"tmpfs|ramfs"} / node_filesystem_size_bytes{fstype!~"tmpfs|ramfs"}) > bool 0.85)'';
      summary = "{{ $labels.mountpoint }} is over 85% full";
      duration = "10m";
    })
    (mkRule {
      uid = "memory-low";
      title = "Low memory";
      expr = "max by (host) ((node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) < bool 0.10)";
      summary = "Available memory is under 10%";
      duration = "10m";
    })
    (mkRule {
      uid = "unit-failed";
      title = "Service failed";
      expr = ''max by (host, name) (node_systemd_unit_state{state="failed"})'';
      summary = "{{ $labels.name }} has failed";
      duration = "2m";
    })
    (mkRule {
      uid = "unit-restarting";
      title = "Service restarting";
      expr = "max by (host, name) (increase(node_systemd_service_restart_total[15m]) > bool 2)";
      summary = "{{ $labels.name }} restarted three times in 15 minutes";
      duration = "0s";
    })
    (mkRule {
      uid = "no-metrics";
      title = "No metrics";
      expr = "absent_over_time(node_boot_time_seconds{host=${hostName}}[10m])";
      summary = "No metrics received for 10 minutes";
      severity = "critical";
      duration = "0s";
    })
  ];

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
      labels        = { host = ${hostName} }
      max_age       = "72h"
    }

    ${containerJournals}
    loki.write "logging" {
      endpoint {
        url                 = "http://${address}:${toString lokiPort}/loki/api/v1/push"
        // Zero retries forever. The default gives up on a batch after about 8 minutes.
        max_backoff_retries = 0
        max_backoff_period  = "30s"
      }
    }

    // Every service, so a failed one is noticed. The container@ ones hold each container's processes.
    prometheus.exporter.unix "host" {
      enable_collectors = ["systemd"]

      systemd {
        unit_include    = ".+\\.service"
        enable_restarts = true
        task_metrics    = true
        start_time      = true
      }
    }

    prometheus.exporter.cadvisor "containers" {
      docker_only                 = false
      raw_cgroup_prefix_allowlist = ["/machine.slice/container@"]
      enabled_metrics             = ["cpu", "memory"]
      storage_duration            = "2m"
    }

    prometheus.scrape "host" {
      targets    = prometheus.exporter.unix.host.targets
      forward_to = [prometheus.relabel.host.receiver]
    }

    prometheus.scrape "containers" {
      targets    = prometheus.exporter.cadvisor.containers.targets
      forward_to = [prometheus.relabel.containers.receiver]
    }

    prometheus.relabel "host" {
      forward_to = [prometheus.remote_write.logging.receiver]

      rule {
        source_labels = ["name"]
        regex         = "container@(.+)\\.service"
        target_label  = "container"
      }
    }

    prometheus.relabel "containers" {
      forward_to = [prometheus.remote_write.logging.receiver]

      rule {
        source_labels = ["id"]
        regex         = "/machine.slice/container@.+\\.service"
        action        = "keep"
      }
      rule {
        source_labels = ["id"]
        regex         = "/machine.slice/container@(.+)\\.service"
        target_label  = "container"
      }
      rule {
        source_labels = ["__name__"]
        regex         = "container_(cpu_usage_seconds_total|memory_working_set_bytes|memory_usage_bytes)"
        action        = "keep"
      }
    }

    prometheus.remote_write "logging" {
      external_labels = { host = ${hostName} }

      endpoint {
        url = "http://${address}:${toString prometheusPort}/api/v1/write"

        queue_config {
          max_backoff = "30s"
        }
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
      # The container gets them as system credentials, because its dynamic UID range hides
      # who owns a file on the host.
      sops.secrets = lib.genAttrs credentials (_: {
        restartUnits = [ "container@grafana.service" ];
      });

      containers.grafana = {
        localAddress = address;
        extraFlags = map (id: "--load-credential=${id}:${config.sops.secrets.${id}.path}") credentials;
        config =
          { config, pkgs, ... }:
          let
            cfg = config.services.grafana;
            tlsCert = "${cfg.dataDir}/tls.crt";
            tlsKey = "${cfg.dataDir}/tls.key";
            credentialsDir = "/run/credentials/grafana.service";
            # The config file the nixpkgs unit starts Grafana with.
            configFile = lib.last (
              lib.splitString " -config " config.systemd.services.grafana.serviceConfig.ExecStart
            );
            openssl = lib.getExe pkgs.openssl;
            checkAddress = if lanAddress != null then lanAddress else address;
          in
          {
            containerFirewall.extraOutputRules = "ip daddr ${ntfy.address} tcp dport ${toString ntfy.httpPort} accept";

            networking.firewall.allowedTCPPorts = [
              grafanaPort
              lokiPort
              prometheusPort
            ];

            services.prometheus = {
              enable = true;
              listenAddress = "0.0.0.0";
              port = prometheusPort;
              retentionTime = "30d";
              extraFlags = [ "--web.enable-remote-write-receiver" ];
            };

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
              # Neither is bundled with Grafana 13, and the container can't download them.
              declarativePlugins = [
                pkgs.grafanaPlugins.loki
                pkgs.grafanaPlugins.prometheus
              ];
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
                security = {
                  secret_key = "$__file{${credentialsDir}/grafana-secret-key}";
                  admin_password = "$__file{${credentialsDir}/grafana-admin-password}";
                  cookie_secure = true;
                  disable_gravatar = true;
                };
                # The default also writes files, which journald's limits wouldn't cover.
                log.mode = "console";
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
                    {
                      name = "Prometheus";
                      uid = "prometheus";
                      type = "prometheus";
                      access = "proxy";
                      url = "http://127.0.0.1:${toString prometheusPort}";
                      editable = false;
                    }
                  ];
                };
                # Only the title and message are sent, so no log lines or links end up on the phone.
                alerting = {
                  templates.settings = {
                    apiVersion = 1;
                    templates = [
                      {
                        name = "ntfy";
                        template = ''
                          {{ define "ntfy.title" -}}
                          {{ if eq .Status "firing" }}Firing{{ else }}Resolved{{ end }}: {{ .GroupLabels.alertname }}
                          {{- end }}

                          {{ define "ntfy.message" -}}
                          {{ range .Alerts -}}
                          {{ .Labels.severity }} on {{ .Labels.host }}: {{ .Annotations.summary }}
                          {{ end -}}
                          {{- end }}
                        '';
                      }
                    ];
                  };
                  contactPoints.settings = {
                    apiVersion = 1;
                    contactPoints = map (ntfyContactPoint credentialsDir) [
                      {
                        name = "ntfy";
                        query = "";
                      }
                      {
                        name = "ntfy-critical";
                        query = "&priority=high";
                      }
                    ];
                  };
                  policies.settings = {
                    apiVersion = 1;
                    policies = [
                      {
                        receiver = "ntfy";
                        group_by = [
                          "alertname"
                          "host"
                        ];
                        group_wait = "30s";
                        group_interval = "5m";
                        repeat_interval = "12h";
                        routes = [
                          {
                            receiver = "ntfy-critical";
                            object_matchers = [
                              [
                                "severity"
                                "="
                                "critical"
                              ]
                            ];
                          }
                        ];
                      }
                    ];
                  };
                  rules.settings = {
                    apiVersion = 1;
                    groups = [
                      {
                        orgId = 1;
                        name = "host";
                        folder = "Alerts";
                        interval = "1m";
                        rules = alertRules;
                      }
                    ];
                  };
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

            systemd.services.grafana.serviceConfig = {
              ImportCredential = credentials;
              # Grafana only reads admin_password when it creates its database, so an existing one is
              # reset to it on each start.
              ExecStartPre = lib.mkAfter [
                (pkgs.writeShellScript "grafana-reset-admin-password" ''
                  [ -e ${cfg.settings.database.path} ] || exit 0
                  exec ${lib.getExe cfg.package} cli --homepath ${cfg.dataDir} --config ${configFile} \
                    admin reset-admin-password --password-from-stdin \
                    < "$CREDENTIALS_DIRECTORY/grafana-admin-password"
                '')
              ];
            };

            # Grafana needs a certificate to start, and doesn't make one.
            systemd.services.grafana.preStart = ''
              umask 077

              # Made again when it's about to expire, or the host's address changes.
              certificate_valid() {
                [ -s ${tlsKey} ] &&
                  ${openssl} x509 -in ${tlsCert} -noout -checkend 2592000 > /dev/null &&
                  ${openssl} x509 -in ${tlsCert} -noout -checkip ${checkAddress} > /dev/null
              }
              if ! certificate_valid; then
                ${openssl} req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 3650 \
                  -subj /CN=grafana -keyout ${tlsKey} -out ${tlsCert} \
                  -addext basicConstraints=critical,CA:FALSE -addext keyUsage=digitalSignature \
                  -addext extendedKeyUsage=serverAuth \
                  -addext "subjectAltName=DNS:grafana,DNS:localhost,IP:127.0.0.1,IP:${address}${
                    lib.optionalString (lanAddress != null) ",IP:${lanAddress}"
                  }"
              fi
            '';
          };
      };

      systemd.services = lib.mkMerge [
        # Alloy opens a journal path once, and nspawn only makes a container's after it first starts.
        (lib.listToAttrs (
          map (name: {
            name = "container@${name}";
            value.serviceConfig.ExecStartPost = "-${pkgs.writeShellScript "alloy-find-${name}-journal" ''
              journal=/var/lib/nixos-containers/${name}/var/log/journal
              started=$(${config.systemd.package}/bin/systemctl show -P ActiveEnterTimestamp --timestamp=unix alloy.service)
              [ -d "$journal" ] && [ -n "$started" ] || exit 0
              if [ "$(${pkgs.coreutils}/bin/stat -c %Y "$journal")" -ge "''${started#@}" ]; then
                ${config.systemd.package}/bin/systemctl try-restart --no-block alloy.service
              fi
            ''}";
          }) containerNames
        ))
        {
          alloy.serviceConfig = {
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

          # A clean exit inside the container counts as success, so on-failure wouldn't restart it.
          "container@grafana" = {
            startLimitIntervalSec = 0;
            serviceConfig = {
              Restart = lib.mkForce "always";
              RestartSec = 5;
            };
          };
        }
      ];

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

      assertions = [
        {
          assertion = lib.length (lib.unique (map componentName containerNames)) == lib.length containerNames;
          message = "Two container names turn into the same Alloy component name.";
        }
      ];

      # Traverse only, to reach the container journals. Alloy lists none of it.
      containerRoot.group = "alloy";

      # Loki and Prometheus have no authentication, so keep other users on the host from them.
      networking.nftables.tables.logging-guard = {
        family = "ip";
        content = ''
          chain output {
            type filter hook output priority filter - 1; policy accept;

            ip daddr ${address} tcp dport { ${toString lokiPort}, ${toString prometheusPort} } meta skuid != { 0, ${toString alloyUid} } drop
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

      # The drop keeps the host's own services, such as SSH, off this address. The output chain
      # covers the host itself, whose traffic to its own address skips prerouting.
      networking.nftables.tables.logging-dnat = {
        family = "ip";
        content = ''
          chain prerouting {
            type nat hook prerouting priority dstnat; policy accept;

            iifname != "lo" iifname != "ve-*" ip daddr ${lanAddress} ip saddr ${privateRanges} tcp dport 443 dnat to ${address}:${toString grafanaPort}
          }

          chain output {
            type nat hook output priority dstnat; policy accept;

            ip daddr ${lanAddress} tcp dport 443 dnat to ${address}:${toString grafanaPort}
          }

          chain input {
            type filter hook input priority filter - 1; policy accept;

            # Grafana's replies to the host come back on ve-grafana.
            iifname != "lo" ct state != { established, related } ip daddr ${lanAddress} drop
          }
        '';
      };
    })
  ];
}
