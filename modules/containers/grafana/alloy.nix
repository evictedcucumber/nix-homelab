# Alloy on the host, shipping its journal, every monitored container's journal, and metrics
# for the host and all containers. Containers can't read the host's journal, so this isn't one.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  endpoint = import ./endpoint.nix;
  # Outside the range NixOS hands out to system users, and unused in ids.nix.
  alloyUid = 399;
  hostName = builtins.toJSON config.networking.hostName;

  monitored = lib.attrNames (lib.filterAttrs (_: c: c.config.container.monitored) config.containers);
  # Component labels are identifiers, so other characters in a container's name become _.
  componentName = lib.stringAsChars (c: if builtins.match "[A-Za-z0-9_]" c != null then c else "_");

  # The label comes from the config, never from the journal, whose fields the container controls.
  containerJournals = lib.concatMapStrings (name: ''
    loki.source.journal "container_${componentName name}" {
      forward_to    = [loki.write.logging.receiver]
      relabel_rules = loki.relabel.journal.rules
      path          = ${builtins.toJSON "/var/lib/nixos-containers/${name}/var/log/journal"}
      labels        = { host = ${hostName}, container = ${builtins.toJSON name} }
      max_age       = "72h"
    }

  '') monitored;
in
{
  # Alloy opens a journal path once, and nspawn only makes a container's after it first starts.
  systemd.services = lib.mkMerge [
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
      }) monitored
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

  environment.etc."alloy/config.alloy".text = import ./alloy-config.nix {
    inherit endpoint hostName containerJournals;
  };

  assertions = [
    {
      assertion = lib.length (lib.unique (map componentName monitored)) == lib.length monitored;
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

        ip daddr ${endpoint.address} tcp dport { ${toString endpoint.lokiPort}, ${toString endpoint.prometheusPort} } meta skuid != { 0, ${toString alloyUid} } drop
      }
    '';
  };
}
