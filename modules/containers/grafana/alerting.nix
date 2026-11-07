# Where Grafana sends alerts: to ntfy, which is the only place the container can reach.
_:
let
  ntfy = import ../ntfy/endpoint.nix;
  credentialsDir = "/run/credentials/grafana.service";

  # The password is read from the credential when Grafana loads it, so it stays out of the store.
  ntfyContactPoint =
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
in
{
  containerFirewall.extraOutputRules = "ip daddr ${ntfy.address} tcp dport ${toString ntfy.httpPort} accept";

  services.grafana.provision.alerting = {
    # Only the title and message are sent, so no log lines or links end up on the phone.
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
      contactPoints = map ntfyContactPoint [
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
  };
}
