# The host's side of containers, shared by all of them. Each container's module imports this.
{
  imports = [
    ./credentials.nix
    ./lan.nix
    ./network.nix
    ./restart.nix
  ];
}
