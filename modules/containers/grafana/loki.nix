# Loki inside the Grafana container, receiving logs from Alloy.
{ config, ... }:
let
  inherit (import ./endpoint.nix) lokiPort;
in
{
  networking.firewall.allowedTCPPorts = [ lokiPort ];

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
}
