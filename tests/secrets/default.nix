# Decrypts a module's secrets in a VM test with a throwaway key, in place of the host's SSH key.
# The key is committed and public, so it protects nothing, and no real host uses it.
{ config, lib, ... }:
{
  sops = {
    defaultSopsFile = lib.mkForce ./secrets.yaml;
    age = {
      keyFile = "/etc/sops-test-age-key.txt";
      sshKeyPaths = lib.mkForce [ ];
    };
  };

  environment.etc."sops-test-age-key.txt".source = ./age-key.txt;
  # The key comes from /etc.
  system.activationScripts = lib.mkIf (config.sops.secrets != { }) { setupSecrets.deps = [ "etc" ]; };
}
