# Restarts a container whenever it stops, which a failed service inside it can't do alone.
{ config, lib, ... }:
{
  options.containers = lib.mkOption {
    type = lib.types.attrsOf (
      lib.types.submodule {
        options.restartAlways = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Restart the container on any exit, after five seconds and with no limit.";
        };
      }
    );
  };

  # A clean exit inside the container counts as success, so on-failure wouldn't restart it.
  config.systemd.services = lib.mapAttrs' (
    name: _:
    lib.nameValuePair "container@${name}" {
      startLimitIntervalSec = 0;
      serviceConfig = {
        Restart = lib.mkForce "always";
        RestartSec = 5;
      };
    }
  ) (lib.filterAttrs (_: c: c.restartAlways) config.containers);
}
