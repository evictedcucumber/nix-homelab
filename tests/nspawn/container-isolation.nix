# The host's container-guard, with each container's own egress firewall opened so it's what's tested.
let
  container = localAddress: {
    inherit localAddress;
    config =
      { pkgs, ... }:
      {
        containerFirewall.extraOutputRules = "accept";
        environment.systemPackages = [ pkgs.curl ];
        networking.firewall.allowedTCPPorts = [ 80 ];
        services.nginx = {
          enable = true;
          virtualHosts.default.locations."/".return = "200 ok";
        };
      };
  };
in
{
  name = "container-isolation";

  containers.machine = {
    imports = [ ./host.nix ];
    containers = {
      a = container "10.233.0.10";
      b = container "10.233.0.11";
    };
    services.openssh.enable = true;
  };

  testScript = ''
    start_all()
    machine.wait_for_unit("container@a.service")
    machine.wait_for_unit("container@b.service")

    # Proves the network is up, so the drops below come from the firewalls.
    machine.wait_until_succeeds("curl -sf --max-time 2 http://10.233.0.10/")
    machine.wait_until_succeeds("curl -sf --max-time 2 http://10.233.0.11/")
    machine.wait_for_open_port(22)

    # nixos-container run can't enter a container's other namespaces in the sandbox.
    leader = machine.succeed("machinectl show a --property=Leader --value").strip()

    def connect_from_a(address, port):
        status, _ = machine.execute(
            f"nsenter --target {leader} --net timeout 3 bash -c '</dev/tcp/{address}/{port}'"
        )
        return status

    # The host has no nginx, so this only connects from inside a.
    with subtest("connections from a's network namespace work"):
        machine.wait_until_succeeds(f"nsenter --target {leader} --net curl -sf --max-time 2 http://127.0.0.1/")

    # 124 is timeout's status: dropped, rather than refused or failing for another reason.
    with subtest("containers can't reach each other"):
        assert connect_from_a("10.233.0.11", 80) == 124

    with subtest("containers can't reach the host's SSH"):
        assert connect_from_a("10.233.0.1", 22) == 124

    with subtest("containers can't reach DNS unless they asked for it"):
        assert connect_from_a("10.233.0.1", 53) == 124
  '';
}
