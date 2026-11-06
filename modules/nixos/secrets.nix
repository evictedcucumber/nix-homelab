# Secrets encrypted per host in secrets/<host>.yaml. A host decrypts them with an age key
# derived from its SSH host key, so reinstalling a host means `just secrets-rekey`.
{ config, ... }:
{
  sops = {
    defaultSopsFile = ../../secrets/${config.networking.hostName}.yaml;
    age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
    gnupg.sshKeyPaths = [ ];
  };
}
