# Grafana's alert rules, all on Prometheus metrics, which Alloy ships from the host.
{ config, ... }:
let
  hostName = builtins.toJSON config.container.hostName;

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

  rules = [
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
in
{
  services.grafana.provision.alerting.rules.settings = {
    apiVersion = 1;
    groups = [
      {
        orgId = 1;
        name = "host";
        folder = "Alerts";
        interval = "1m";
        inherit rules;
      }
    ];
  };
}
