# Grafana inside its container, with Loki and Prometheus as data sources and the dashboards.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (import ./endpoint.nix) grafanaPort lokiPort prometheusPort;
  inherit (config.container) lanAddress;
  cfg = config.services.grafana;
  credentialsDir = "/run/credentials/grafana.service";
  # The config file the nixpkgs unit starts Grafana with.
  configFile = lib.last (
    lib.splitString " -config " config.systemd.services.grafana.serviceConfig.ExecStart
  );

  dashboards = pkgs.symlinkJoin {
    name = "grafana-dashboards";
    paths = [
      (pkgs.writeTextDir "host-logs.json" (builtins.readFile ./dashboards/host-logs.json))
      (pkgs.writeTextDir "containers.json" (builtins.readFile ./dashboards/containers.json))
    ];
  };
in
{
  container.tls = {
    service = "grafana";
    directory = cfg.dataDir;
  };

  networking.firewall.allowedTCPPorts = [ grafanaPort ];

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
        cert_file = config.container.tls.certFile;
        cert_key = config.container.tls.keyFile;
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
    ImportCredential = config.container.credentials;
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
}
