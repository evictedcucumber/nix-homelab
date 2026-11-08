# Evaluates the hosts with one thing broken at a time and checks which assertion fails.
# Only `config.assertions` is forced, never the system build.
{
  lib,
  pkgs,
  hosts,
}:
let
  failed =
    host: modules:
    let
      cfg = if modules == [ ] then host else host.extendModules { inherit modules; };
    in
    map (a: a.message) (lib.filter (a: !a.assertion) cfg.config.assertions);

  container = address: {
    localAddress = address;
    config = { };
  };

  monitoredContainer = address: {
    localAddress = address;
    config.imports = [ ../../modules/containers/guest/monitoring.nix ];
  };

  # Fails when no failing assertion contains `expect`, or when `expect` is null and any does.
  mkCase =
    name: host: modules: expect:
    let
      msgs = failed host modules;
      hit = lib.any (m: lib.hasInfix expect m) msgs;
    in
    {
      inherit name;
      ok = if expect == null then msgs == [ ] else hit && lib.length msgs == 1;
      detail = builtins.toJSON msgs;
    };

  d = hosts.dcyclops;

  # A key sops leaves in the clear, with its value encrypted.
  encrypted = file: key: lib.hasInfix "\n${key}: ENC[" ("\n" + builtins.readFile file);
  secretsCase =
    name: host:
    let
      missing = lib.filter (s: !encrypted s.sopsFile s.name) (lib.attrValues host.config.sops.secrets);
    in
    {
      name = "${name}'s secrets file is encrypted and holds every secret";
      ok = missing == [ ];
      detail = "missing or unencrypted: ${toString (map (s: s.name) missing)}";
    };

  # The tests' throwaway key must never stand in for a real host's secrets.
  realSecretsCase =
    name: host:
    let
      files = [
        host.config.sops.defaultSopsFile
      ]
      ++ map (s: s.sopsFile) (lib.attrValues host.config.sops.secrets);
      stray = lib.filter (f: lib.hasInfix "/tests/" (toString f)) files;
    in
    {
      name = "${name} reads its secrets from secrets/, not tests/";
      ok =
        stray == [ ]
        && toString host.config.sops.defaultSopsFile == toString (../../secrets + "/${name}.yaml");
      detail = "files: ${toString (map toString files)}";
    };

  limitCase =
    name: host:
    let
      limit = host.config.boot.loader.systemd-boot.configurationLimit;
    in
    {
      name = "${name} caps its boot generations";
      ok = limit != null && limit <= 20;
      detail = "configurationLimit: ${builtins.toJSON limit}";
    };

  cases = [
    (mkCase "dcyclops passes" hosts.dcyclops [ ] null)
    (mkCase "tcyclops passes" hosts.tcyclops [ ] null)

    (mkCase "duplicate container address" d [
      { containers.dup = container "10.233.0.2"; }
    ] "unique localAddress")
    (mkCase "container address outside the subnet" d [
      { containers.out = container "10.234.0.9"; }
    ] "unique localAddress")
    (mkCase "container address is the host's" d [
      { containers.out = container "10.233.0.1"; }
    ] "unique localAddress")
    (mkCase "container address with a prefix length" d [
      { containers.out = container "10.233.0.9/24"; }
    ] "unique localAddress")
    (mkCase "container without a private network" d [
      { containers.pihole.privateNetwork = lib.mkForce false; }
    ] "keep their private network")
    (mkCase "container with a macvlan" d [
      { containers.pihole.macvlans = [ "eth0" ]; }
    ] "keep their private network")
    (mkCase "container on a bridge" d [
      { containers.pihole.hostBridge = "br0"; }
    ] "keep their private network")
    (mkCase "container with an extra capability" d [
      { containers.pihole.additionalCapabilities = [ "CAP_NET_ADMIN" ]; }
    ] "keep their private network")
    (mkCase "container with a --network- flag" d [
      { containers.pihole.extraFlags = [ "--network-macvlan=eth0" ]; }
    ] "keep their private network")

    (mkCase "captain without an SSH key" d [
      { users.users.captain.openssh.authorizedKeys.keys = lib.mkForce [ ]; }
    ] "Add an SSH public key")

    (mkCase "captain without a password hash" d [
      { users.users.captain.hashedPassword = lib.mkForce null; }
    ] "just set-password captain")
    (mkCase "riley with a sha512 hash" d [
      { users.users.riley.hashedPassword = lib.mkForce "$6$salt$hash"; }
    ] "just set-password riley")
    (mkCase "both logins without a hash" d [
      {
        users.users.captain.hashedPassword = lib.mkForce null;
        users.users.riley.hashedPassword = lib.mkForce "";
      }
    ] "just set-password captain', run 'just set-password riley")

    (secretsCase "dcyclops" hosts.dcyclops)
    (secretsCase "tcyclops" hosts.tcyclops)
    (realSecretsCase "dcyclops" hosts.dcyclops)
    (realSecretsCase "tcyclops" hosts.tcyclops)

    (limitCase "dcyclops" hosts.dcyclops)
    (limitCase "tcyclops" hosts.tcyclops)

    (mkCase "pihole's LAN address not on an interface" d [
      { containers.pihole.lan.address = lib.mkForce "172.16.9.9"; }
    ] "containers.pihole.lan.address")
    (mkCase "grafana's LAN address not on an interface" d [
      { containers.grafana.lan.address = lib.mkForce "172.16.9.9"; }
    ] "containers.grafana.lan.address")
    (mkCase "ntfy's LAN address not on an interface" d [
      { containers.ntfy.lan.address = lib.mkForce "172.16.9.9"; }
    ] "containers.ntfy.lan.address")
    (mkCase "allowFrom naming a missing container" d [
      { containers.pihole.config.containerFirewall.allowFrom.missing = [ 80 ]; }
    ] "allowFrom")

    (mkCase "container names with one Alloy component name" d [
      {
        containers = {
          "a-b" = monitoredContainer "10.233.0.20";
          "a_b" = monitoredContainer "10.233.0.21";
        };
      }
    ] "same Alloy component name")
  ];

  bad = lib.filter (c: !c.ok) cases;
in
assert lib.assertMsg (bad == [ ]) ''
  Eval test cases failed:
  ${lib.concatMapStringsSep "\n" (c: "  ${c.name}: failing assertions ${c.detail}") bad}
'';
pkgs.runCommand "eval-tests" { } ''
  echo ${lib.escapeShellArg (lib.concatMapStringsSep "\n" (c: "ok: ${c.name}") cases)}
  touch $out
''
