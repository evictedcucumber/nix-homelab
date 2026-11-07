let
  address = "10.233.0.2";
in
{
  name = "pihole";

  containers.machine =
    { pkgs, ... }:
    {
      imports = [
        ./host.nix
        ../../modules/containers/pihole
      ];
      environment.systemPackages = [ pkgs.dig ];
    };

  # There's no upstream in the sandbox, so this doesn't cover lookups or the blocklist.
  testScript = ''
    import json
    import shlex

    start_all()
    machine.wait_for_unit("container@pihole.service")

    with subtest("FTL answers DNS"):
        machine.wait_until_succeeds("dig +short +time=2 +tries=1 @${address} pi.hole | grep -q .", timeout=120)

    with subtest("the web interface answers over TLS"):
        machine.wait_until_succeeds("curl -skf --max-time 5 https://${address}/admin/ -o /dev/null", timeout=120)

    # The password sops decrypted on the host, which the container got as a credential.
    password = machine.succeed("cat /run/secrets/pihole-web-password")
    assert password

    def login(password):
        reply = machine.succeed(
            f"curl -sk --max-time 5 -X POST https://${address}/api/auth -d {shlex.quote(json.dumps({'password': password}))}"
        )
        return json.loads(reply)["session"]["valid"]

    with subtest("the web API accepts the password from the secrets file"):
        machine.wait_until_succeeds("curl -sk --max-time 5 https://${address}/api/auth | grep -q session", timeout=60)
        assert login(password)

    with subtest("the web API rejects other passwords"):
        assert not login(password + "x")
        assert not login("")

    # What a deploy does once sops has a new value: the container restarts and loads it.
    with subtest("a changed secret replaces the password the container already has"):
        machine.succeed("systemctl stop container@pihole.service")
        machine.succeed("printf %s changed-password > \"$(readlink -f /run/secrets/pihole-web-password)\"")
        machine.succeed("systemctl start container@pihole.service")
        machine.wait_until_succeeds("curl -sk --max-time 5 https://${address}/api/auth | grep -q session", timeout=120)
        assert login("changed-password")
        assert not login(password)

    # FTL must not run without a password, which is what an empty credential would give it.
    with subtest("an empty secret keeps FTL from starting"):
        machine.succeed("systemctl stop container@pihole.service")
        machine.succeed(": > \"$(readlink -f /run/secrets/pihole-web-password)\"")
        machine.succeed("systemctl start container@pihole.service")
        machine.wait_for_unit("container@pihole.service")
        for _ in range(10):
            machine.fail("curl -sk --max-time 3 https://${address}/api/auth")
            machine.sleep(2)
        machine.succeed("printf %s changed-password > \"$(readlink -f /run/secrets/pihole-web-password)\"")
        machine.succeed("systemctl restart container@pihole.service")
        machine.wait_until_succeeds("curl -sk --max-time 5 https://${address}/api/auth | grep -q session", timeout=120)
        assert login("changed-password")
  '';
}
