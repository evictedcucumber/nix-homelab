let
  lanAddress = "192.168.1.50";
in
{
  name = "logging";

  containers = {
    machine = {
      imports = [
        ./host.nix
        ../../modules/containers/grafana
      ];
      containers.grafana.lan.address = lanAddress;
      virtualisation.vlans = [ 1 ];
      networking.interfaces.eth1.ipv4.addresses = [
        {
          address = "192.168.1.2";
          prefixLength = 24;
        }
        {
          address = lanAddress;
          prefixLength = 24;
        }
      ];
    };

    client.virtualisation.vlans = [ 1 ];
  };

  testScript = ''
    import json
    import shlex

    start_all()
    machine.wait_for_unit("container@grafana.service")
    machine.wait_until_succeeds("curl -sf --max-time 2 http://10.233.0.3:3100/ready", timeout=120)

    with subtest("Alloy ships the host's journal to Loki"):
        machine.wait_until_succeeds(
            "curl -sfG --max-time 5 http://10.233.0.3:3100/loki/api/v1/label/host/values | grep -q machine",
            timeout=120,
        )

    with subtest("Alloy ships each container's journal with its name"):
        machine.wait_until_succeeds(
            "curl -sfG --max-time 5 http://10.233.0.3:3100/loki/api/v1/label/container/values | grep -q grafana",
            timeout=180,
        )

    with subtest("Prometheus has the container's state, CPU and memory"):
        for query in [
            'node_systemd_unit_state{container="grafana",state="active"} == 1',
            'container_cpu_usage_seconds_total{container="grafana"}',
            'container_memory_working_set_bytes{container="grafana"}',
        ]:
            machine.wait_until_succeeds(
                f"curl -sfG --max-time 5 http://10.233.0.3:9090/api/v1/query --data-urlencode 'query={query}' | grep -q '\"container\":\"grafana\"'",
                timeout=180,
            )

    with subtest("restarting a container with a journal Alloy already reads leaves Alloy running"):
        alloy = machine.succeed("systemctl show -P InvocationID alloy.service").strip()
        machine.succeed("systemctl restart container@grafana.service")
        machine.wait_until_succeeds("curl -sf --max-time 2 http://10.233.0.3:3100/ready", timeout=120)
        assert machine.succeed("systemctl show -P InvocationID alloy.service").strip() == alloy

    with subtest("only Alloy and root can reach Loki and Prometheus"):
        machine.fail("setpriv --reuid=65534 --clear-groups curl -sf --max-time 3 http://10.233.0.3:3100/ready")
        machine.fail("setpriv --reuid=65534 --clear-groups curl -sf --max-time 3 http://10.233.0.3:9090/-/ready")

    with subtest("Grafana answers over TLS on its LAN address"):
        client.wait_until_succeeds("curl -skf --max-time 5 https://${lanAddress}/api/health", timeout=120)

    with subtest("the host reaches Grafana on its LAN address"):
        machine.succeed("curl -skf --max-time 5 https://${lanAddress}/api/health")

    # The password sops decrypted on the host, which the container got as a credential.
    password = machine.succeed("cat /run/secrets/grafana-admin-password")
    assert password

    def grafana(password, path="api/org", data=None):
        method = f"-X PUT -H 'Content-Type: application/json' -d {shlex.quote(json.dumps(data))}" if data else ""
        return machine.execute(
            f"curl -sk --max-time 5 -o /dev/null -w '%{{http_code}}' -u {shlex.quote('admin:' + password)} {method} https://${lanAddress}/{path}"
        )[1]

    with subtest("Grafana accepts the admin password from the secrets file"):
        assert grafana(password) == "200"

    with subtest("Grafana rejects another password"):
        assert grafana(password + "x") == "401"

    # The database already has a password after the first start, which Grafana wouldn't read
    # from its config again.
    with subtest("a restart resets a changed admin password to the secret"):
        changed = {"oldPassword": password, "newPassword": "changed-password", "confirmNew": "changed-password"}
        assert grafana(password, "api/user/password", changed) == "200"
        assert grafana("changed-password") == "200"
        machine.succeed("systemctl restart container@grafana.service")
        machine.wait_until_succeeds("curl -skf --max-time 5 https://${lanAddress}/api/health", timeout=120)
        assert grafana(password) == "200"
        assert grafana("changed-password") == "401"

    with subtest("the LAN address only exposes Grafana"):
        client.fail("curl -s --max-time 3 telnet://${lanAddress}:22")
  '';
}
