let
  lanAddress = "192.168.1.50";
  stateDir = "/var/lib/nixos-containers/ntfy/var/lib/private/ntfy-sh";
in
{
  name = "ntfy";

  containers = {
    machine = {
      imports = [
        ./host.nix
        ../../modules/nixos/logging.nix
        ../../modules/nixos/ntfy.nix
        ../../modules/containers/pihole
      ];
      ntfy = { inherit lanAddress; };
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

    client = {
      virtualisation.vlans = [ 1 ];
    };
  };

  testScript = ''
    import json
    import shlex

    start_all()
    for name in ["ntfy", "grafana", "pihole"]:
        machine.wait_for_unit(f"container@{name}.service")
    machine.wait_until_succeeds("curl -sf --max-time 2 http://10.233.0.4:8080/v1/health", timeout=120)

    # The passwords sops decrypted on the host, which the containers got as credentials.
    grafana_password = machine.succeed("cat /run/secrets/ntfy-grafana-password")
    phone_password = machine.succeed("cat /run/secrets/ntfy-phone-password")
    assert grafana_password and phone_password and grafana_password != phone_password

    def ntfy(method, user=None, password=None, data="", path="alerts", base="http://10.233.0.4:8080"):
        auth = f"-u {shlex.quote(user + ':' + password)}" if user else ""
        return machine.execute(
            f"curl -s --max-time 5 -o /dev/null -w '%{{http_code}}' -X {method} {auth} -d {shlex.quote(data)} {base}/{path}"
        )[1]

    def read(user, password):
        out = machine.succeed(
            f"curl -sf --max-time 5 -u {shlex.quote(user + ':' + password)} 'http://10.233.0.4:8080/alerts/json?poll=1&since=all'"
        )
        return [m for m in map(json.loads, out.splitlines()) if m["event"] == "message"]

    with subtest("anonymous users can neither publish nor subscribe"):
        assert ntfy("POST", data="anon") in ("401", "403")
        assert ntfy("GET", path="alerts/json?poll=1") in ("401", "403")

    with subtest("wrong passwords are refused"):
        assert ntfy("POST", "grafana", phone_password, "x") == "401"
        assert ntfy("POST", "phone", grafana_password, "x") == "401"
        assert ntfy("POST", "nobody", phone_password, "x") == "401"

    with subtest("grafana can publish to alerts but not read it, or publish elsewhere"):
        assert ntfy("POST", "grafana", grafana_password, "from-grafana") == "200"
        assert ntfy("GET", "grafana", grafana_password, path="alerts/json?poll=1") == "403"
        assert ntfy("POST", "grafana", grafana_password, "x", path="other") == "403"

    with subtest("phone can read alerts but not publish, or read elsewhere"):
        assert [m["message"] for m in read("phone", phone_password)] == ["from-grafana"]
        assert ntfy("POST", "phone", phone_password, "x") == "403"
        assert ntfy("GET", "phone", phone_password, path="other/json?poll=1") == "403"

    with subtest("the web app is off"):
        assert ntfy("GET", "phone", phone_password, path="") == "404"

    with subtest("the LAN address answers HTTPS with its certificate, and only on 443"):
        pem = machine.succeed("cat ${stateDir}/tls.crt")
        client.succeed(f"cat > /tmp/ntfy.pem << 'EOF'\n{pem}EOF")
        client.wait_until_succeeds("curl -sf --max-time 5 --cacert /tmp/ntfy.pem https://${lanAddress}/v1/health", timeout=60)
        client.fail("curl -s --max-time 3 http://${lanAddress}:8080/v1/health")
        client.fail("curl -sk --max-time 3 https://${lanAddress}:8443/v1/health")
        client.fail("curl -s --max-time 3 telnet://${lanAddress}:22")
        assert client.succeed(
            f"curl -s --max-time 5 --cacert /tmp/ntfy.pem -u {shlex.quote('phone:' + phone_password)} 'https://${lanAddress}/alerts/json?poll=1&since=all'"
        )

    with subtest("the host reaches ntfy on its LAN address"):
        machine.succeed("curl -skf --max-time 5 https://${lanAddress}/v1/health")

    # A rule that always fires, so the policy, template and contact point carry its alert to
    # ntfy with the password from Grafana's credential.
    grafana = "curl -sk --max-time 10 -u " + shlex.quote("admin:" + machine.succeed("cat /run/secrets/grafana-admin-password"))

    with subtest("Grafana delivers an alert to ntfy"):
        machine.wait_until_succeeds("curl -skf --max-time 5 https://10.233.0.3:3000/api/health", timeout=120)
        folders = json.loads(machine.succeed(f"{grafana} --fail-with-body https://10.233.0.3:3000/api/folders"))
        folder = next(f["uid"] for f in folders if f["title"] == "Alerts")
        def always_firing(uid, severity):
            return {
                "uid": uid, "title": uid, "ruleGroup": "test", "folderUID": folder, "orgID": 1,
                "condition": "A", "for": "0s", "noDataState": "NoData", "execErrState": "Error",
                "data": [{"refId": "A", "relativeTimeRange": {"from": 0, "to": 0}, "datasourceUid": "__expr__",
                          "model": {"type": "math", "expression": "1", "refId": "A"}}],
                "labels": {"host": "machine", "severity": severity},
                "annotations": {"summary": "short summary"},
            }

        group = {"title": "test", "interval": 10, "rules": [always_firing("TestAlert", "warning"), always_firing("TestCritical", "critical")]}
        machine.succeed(
            f"{grafana} --fail-with-body -X PUT -H 'Content-Type: application/json' -d {shlex.quote(json.dumps(group))}"
            f" https://10.233.0.3:3000/api/v1/provisioning/folder/{folder}/rule-groups/test"
        )
        machine.wait_until_succeeds(
            "curl -sf --max-time 5 -u " + shlex.quote("phone:" + phone_password)
            + " 'http://10.233.0.4:8080/alerts/json?poll=1&since=all' > /tmp/alerts"
            + " && grep -q TestAlert /tmp/alerts && grep -q TestCritical /tmp/alerts",
            timeout=240,
        )
        delivered = {m["title"].split(": ")[-1]: m for m in read("phone", phone_password) if "Test" in m.get("title", "")}
        # No link, action or attachment comes with them.
        for m in delivered.values():
            assert set(m) <= {"id", "time", "expires", "event", "topic", "title", "message", "priority"}, m
        assert sorted(delivered) == ["TestAlert", "TestCritical"], delivered
        assert delivered["TestAlert"]["title"].endswith("Firing: TestAlert"), delivered
        assert delivered["TestAlert"]["message"].strip() == "warning on machine: short summary", delivered
        assert delivered["TestAlert"].get("priority", 3) == 3, delivered
        assert delivered["TestCritical"]["message"].strip() == "critical on machine: short summary", delivered
        assert delivered["TestCritical"]["priority"] == 4, delivered
        for uid in ["TestAlert", "TestCritical"]:
            machine.succeed(f"{grafana} --fail-with-body -X DELETE https://10.233.0.3:3000/api/v1/provisioning/alert-rules/{uid}")

    with subtest("the alert rules are loaded and their queries run"):
        rules = json.loads(machine.succeed(f"{grafana} https://10.233.0.3:3000/api/prometheus/grafana/api/v1/rules"))
        found = {r["name"]: r for g in rules["data"]["groups"] for r in g["rules"]}
        assert set(found) == {"Filesystem almost full", "Low memory", "Service failed", "Service restarting", "No metrics"}, list(found)
        assert found["Filesystem almost full"]["annotations"]["summary"] == "{{ $labels.mountpoint }} is over 85% full", found

        def evaluated():
            rules = json.loads(machine.succeed(f"{grafana} https://10.233.0.3:3000/api/prometheus/grafana/api/v1/rules"))
            health = [r["health"] for g in rules["data"]["groups"] for r in g["rules"]]
            assert len(health) == 5 and "error" not in health, health
            return all(h in ("ok", "nodata") for h in health)

        for _ in range(24):
            if evaluated():
                break
            machine.sleep(5)
        else:
            raise Exception("the rules did not all evaluate")

    with subtest("Prometheus has the metrics the rules use"):
        for query in [
            'node_filesystem_size_bytes{host="machine",fstype!~"tmpfs|ramfs"}',
            'node_filesystem_avail_bytes{host="machine",fstype!~"tmpfs|ramfs"}',
            'node_memory_MemAvailable_bytes{host="machine"}',
            'node_memory_MemTotal_bytes{host="machine"}',
            'node_systemd_unit_state{host="machine",state="failed",name="alloy.service"}',
            'node_systemd_service_restart_total{host="machine",name="alloy.service"}',
            'node_boot_time_seconds{host="machine"}',
        ]:
            machine.wait_until_succeeds(
                f"curl -sfG --max-time 5 http://10.233.0.3:9090/api/v1/query --data-urlencode {shlex.quote('query=' + query)} | grep -q '\"value\"'",
                timeout=180,
            )

    # Root in a container can flush its own firewall, so the host's rules are what's left.
    def connect_from(container, address, port):
        leader = machine.succeed(f"machinectl show {container} --property=Leader --value").strip()
        machine.execute(f"nsenter --target {leader} --net nft delete table inet egress")
        status, _ = machine.execute(f"nsenter --target {leader} --net timeout 3 bash -c '</dev/tcp/{address}/{port}'")
        return status

    with subtest("Grafana can reach only ntfy's HTTP port, with its own firewall out of the way"):
        assert connect_from("grafana", "10.233.0.4", 8080) == 0
        assert connect_from("grafana", "10.233.0.4", 8443) == 124
        assert connect_from("grafana", "10.233.0.4", 22) == 124

    with subtest("Pi-hole can't reach ntfy at all"):
        assert connect_from("pihole", "10.233.0.4", 8080) == 124
        assert connect_from("pihole", "10.233.0.4", 8443) == 124

    with subtest("ntfy can't reach Grafana"):
        assert connect_from("ntfy", "10.233.0.3", 3000) == 124

    # What a deploy does once sops has a new value: the container restarts and loads it.
    with subtest("a changed secret replaces the password the container already has"):
        machine.succeed("systemctl stop container@ntfy.service")
        machine.succeed("printf %s changed-password > \"$(readlink -f /run/secrets/ntfy-phone-password)\"")
        machine.succeed("systemctl start container@ntfy.service")
        machine.wait_until_succeeds("curl -sf --max-time 2 http://10.233.0.4:8080/v1/health", timeout=120)
        assert ntfy("GET", "phone", "changed-password", path="alerts/json?poll=1") == "200"
        assert ntfy("GET", "phone", phone_password, path="alerts/json?poll=1") == "401"

    # ntfy must not run with a user that has no password, which is what an empty credential gives.
    with subtest("an empty secret keeps ntfy from starting"):
        machine.succeed("systemctl stop container@ntfy.service")
        machine.succeed(": > \"$(readlink -f /run/secrets/ntfy-grafana-password)\"")
        machine.succeed("systemctl start container@ntfy.service")
        machine.wait_for_unit("container@ntfy.service")
        for _ in range(10):
            machine.fail("curl -s --max-time 2 http://10.233.0.4:8080/v1/health")
            machine.sleep(2)
        journal = machine.succeed("journalctl -M ntfy -u ntfy-sh --no-pager")
        assert "empty ntfy-grafana-password" in journal, journal
        assert "Failed with result" in journal, journal
        machine.succeed(f"printf %s {shlex.quote(grafana_password)} > \"$(readlink -f /run/secrets/ntfy-grafana-password)\"")
        machine.succeed("systemctl restart container@ntfy.service")
        machine.wait_until_succeeds("curl -sf --max-time 2 http://10.233.0.4:8080/v1/health", timeout=120)
        assert ntfy("POST", "grafana", grafana_password, "again") == "200"
  '';
}
