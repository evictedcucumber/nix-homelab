# The daemon's policy from common.nix: only root is trusted, so a non-root user's paths must be signed.
{ pkgs, lib, ... }:
let
  mkKey =
    name:
    pkgs.runCommand "test-signing-key-${name}"
      {
        nativeBuildInputs = [ pkgs.nix ];
      }
      ''
        export NIX_STATE_DIR=$TMPDIR NIX_LOG_DIR=$TMPDIR
        mkdir $out
        nix-store --generate-binary-cache-key ${name} $out/secret $out/public
      '';
  testKey = mkKey "test-1";
  backupKey = mkKey "test-2";
in
{
  name = "nix-signing";

  nodes.machine = {
    imports = [ ../modules/nixos/common.nix ];
    # Only the keys are swapped, for throwaway ones.
    nix.settings.trusted-public-keys = lib.mkForce [
      (lib.trim (builtins.readFile "${testKey}/public"))
      (lib.trim (builtins.readFile "${backupKey}/public"))
    ];
  };

  testScript = ''
    machine.wait_for_unit("multi-user.target")
    as_captain = "runuser -u captain -- "

    # Input-addressed, built unsandboxed with the shell from the VM closure, because content-addressed paths need no signature.
    for name in ["unsigned", "signed", "backup"]:
        expr = f'derivation {{ name = "{name}"; system = builtins.currentSystem; builder = "${pkgs.runtimeShell}"; args = ["-c" "echo {name} > $out"]; }}'
        machine.succeed(f"nix build --impure --no-link --max-jobs 1 --option sandbox false --print-out-paths --expr '{expr}' > /tmp/{name}.path")
    machine.succeed("nix store sign --key-file ${testKey}/secret $(cat /tmp/signed.path)")
    machine.succeed("nix store sign --key-file ${backupKey}/secret $(cat /tmp/backup.path)")

    for name in ["unsigned", "signed", "backup"]:
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

    with subtest("captain can add a path signed by the backup key"):
        machine.succeed(as_captain + "nix copy --from file:///tmp/backup-cache $(cat /tmp/backup.path)")
        machine.succeed("test -e $(cat /tmp/backup.path)")

    with subtest("root can import an unsigned path, as in key recovery"):
        machine.succeed("nix-store --import < /tmp/unsigned.nar")
        machine.succeed("test -e $(cat /tmp/unsigned.path)")
  '';
}
