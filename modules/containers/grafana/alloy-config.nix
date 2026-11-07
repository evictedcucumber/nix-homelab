# Alloy's config: ships journals to Loki, and the host's and containers' metrics to Prometheus.
{
  endpoint,
  hostName,
  containerJournals,
}:
''
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
      url                 = "http://${endpoint.address}:${toString endpoint.lokiPort}/loki/api/v1/push"
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
      url = "http://${endpoint.address}:${toString endpoint.prometheusPort}/api/v1/write"

      queue_config {
        max_backoff = "30s"
      }
    }
  }
''
