# The daemon's policy from common.nix: only root is trusted, so a non-root user's paths must be signed.
{ pkgs, lib, ... }:
let
  testKey =
    pkgs.runCommand "test-signing-key"
      {
        nativeBuildInputs = [ pkgs.nix ];
      }
      ''
        export NIX_STATE_DIR=$TMPDIR NIX_LOG_DIR=$TMPDIR
        mkdir $out
        nix-store --generate-binary-cache-key test-1 $out/secret $out/public
      '';
in
{
  name = "nix-signing";

  nodes.machine = {
    imports = [ ../modules/nixos/common.nix ];
    # Only the key is swapped, for a throwaway one.
    nix.settings.trusted-public-keys = lib.mkForce [
      (lib.trim (builtins.readFile "${testKey}/public"))
    ];
  };

  testScript = ''
    machine.wait_for_unit("multi-user.target")
    as_captain = "runuser -u captain -- "

    # Input-addressed, built unsandboxed with the shell from the VM closure, because content-addressed paths need no signature.
    for name in ["unsigned", "signed"]:
        expr = f'derivation {{ name = "{name}"; system = builtins.currentSystem; builder = "${pkgs.runtimeShell}"; args = ["-c" "echo {name} > $out"]; }}'
        machine.succeed(f"nix build --impure --no-link --max-jobs 1 --option sandbox false --print-out-paths --expr '{expr}' > /tmp/{name}.path")
    machine.succeed("nix store sign --key-file ${testKey}/secret $(cat /tmp/signed.path)")

    for name in ["unsigned", "signed"]:
        machine.succeed(f"nix copy --to file:///tmp/{name}-cache $(cat /tmp/{name}.path)")
        machine.succeed(f"nix-store --export $(cat /tmp/{name}.path) > /tmp/{name}.nar")
        machine.succeed(f"nix-store --delete $(cat /tmp/{name}.path)")
    machine.succeed("chmod -R a+rX /tmp")

    with subtest("captain is not trusted"):
        machine.fail(as_captain + "nix config show trusted-users | grep -w captain")

    with subtest("captain cannot add an unsigned path"):
        machine.fail(as_captain + "nix copy --from file:///tmp/unsigned-cache $(cat /tmp/unsigned.path)")
        machine.fail("test -e $(cat /tmp/unsigned.path)")

    with subtest("captain can add a path signed by a trusted key"):
        machine.succeed(as_captain + "nix copy --from file:///tmp/signed-cache $(cat /tmp/signed.path)")
        machine.succeed("test -e $(cat /tmp/signed.path)")

    with subtest("root can import an unsigned path, as in key recovery"):
        machine.succeed("nix-store --import < /tmp/unsigned.nar")
        machine.succeed("test -e $(cat /tmp/unsigned.path)")
  '';
}
