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
        ../../modules/nixos/pihole.nix
      ];
      environment.systemPackages = [ pkgs.dig ];
    };

  # There's no upstream in the sandbox, so this doesn't cover lookups or the blocklist.
  testScript = ''
    start_all()
    machine.wait_for_unit("container@pihole.service")

    with subtest("FTL answers DNS"):
        machine.wait_until_succeeds("dig +short +time=2 +tries=1 @${address} pi.hole | grep -q .", timeout=120)

    with subtest("the web interface answers over TLS"):
        machine.wait_until_succeeds("curl -skf --max-time 5 https://${address}/admin/ -o /dev/null", timeout=120)
  '';
}
