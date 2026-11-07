# Where Grafana, Loki and Prometheus listen inside their container. Shared by what talks to them.
{
  address = "10.233.0.3";
  grafanaPort = 3000;
  lokiPort = 3100;
  prometheusPort = 9090;
}
