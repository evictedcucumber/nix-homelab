# The host's container-guard, with each container's own egress firewall opened so it's what's tested.
let
  container = localAddress: extra: {
    inherit localAddress;
    config =
      { pkgs, ... }:
      {
        imports = [ extra ];
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
      a = container "10.233.0.10" { };
      # Lets a in on port 80, and also listens on 81, which nothing opens to a.
      b = container "10.233.0.11" {
        containerFirewall.allowFrom.a = [ 80 ];
        networking.firewall.allowedTCPPorts = [ 81 ];
        services.nginx.virtualHosts.second = {
          listen = [
            {
              addr = "0.0.0.0";
              port = 81;
            }
          ];
          locations."/".return = "200 ok";
        };
      };
      c = container "10.233.0.12" { };
    };
    services.openssh.enable = true;
  };

  testScript = ''
    start_all()
    machine.wait_for_unit("container@a.service")
    machine.wait_for_unit("container@b.service")
    machine.wait_for_unit("container@c.service")

    # Proves the network is up, so the drops below come from the firewalls.
    machine.wait_until_succeeds("curl -sf --max-time 2 http://10.233.0.10/")
    machine.wait_until_succeeds("curl -sf --max-time 2 http://10.233.0.11/")
    machine.wait_until_succeeds("curl -sf --max-time 2 http://10.233.0.12/")
    machine.wait_for_open_port(22)

    # nixos-container run can't enter a container's other namespaces in the sandbox.
    def connect_from(container, address, port):
        leader = machine.succeed(f"machinectl show {container} --property=Leader --value").strip()
        status, _ = machine.execute(
            f"nsenter --target {leader} --net timeout 3 bash -c '</dev/tcp/{address}/{port}'"
        )
        return status

    def connect_from_a(address, port):
        return connect_from("a", address, port)

    leader = machine.succeed("machinectl show a --property=Leader --value").strip()

    # The host has no nginx, so this only connects from inside a.
    with subtest("connections from a's network namespace work"):
        machine.wait_until_succeeds(f"nsenter --target {leader} --net curl -sf --max-time 2 http://127.0.0.1/")

    # 124 is timeout's status: dropped, rather than refused or failing for another reason.
    with subtest("containers can't reach each other"):
        assert connect_from_a("10.233.0.12", 80) == 124
        assert connect_from("c", "10.233.0.10", 80) == 124

    with subtest("a container can reach another only on the ports it allowed it"):
        assert connect_from_a("10.233.0.11", 80) == 0
        assert connect_from_a("10.233.0.11", 81) == 124
        assert connect_from_a("10.233.0.11", 22) == 124

    with subtest("allowing one container doesn't allow the others, or the reverse"):
        assert connect_from("c", "10.233.0.11", 80) == 124
        assert connect_from("b", "10.233.0.10", 80) == 124

    with subtest("containers can't reach the host's SSH"):
        assert connect_from_a("10.233.0.1", 22) == 124

    with subtest("containers can't reach DNS unless they asked for it"):
        assert connect_from_a("10.233.0.1", 53) == 124
  '';
}
