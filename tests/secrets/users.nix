# Throwaway login hashes of "throwaway-test-password", for tests that boot a real host.
{ lib, ... }:
let
  hash = "$y$j9T$cmi6dl..BFI0achE2ApqA/$9cnG.vKU46DY/pAXqNGI5A/6bJy3.LI2PiXuvp5luaB";
in
{
  users.users = {
    captain.hashedPassword = lib.mkForce hash;
    riley.hashedPassword = lib.mkForce hash;
    # The test driver sets root's.
    root.hashedPassword = lib.mkForce null;
  };
}
