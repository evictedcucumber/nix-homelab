# Server package set: no docs, desktop data or tools the hosts can't use. Deploys
# run from WSL, so hosts only need Nix to receive a closure and activate it.
{ modulesPath, ... }:
{
  imports = [ (modulesPath + "/profiles/minimal.nix") ];

  system.disableInstallerTools = true;
  # `just hardware-config` runs this on the host.
  system.tools.nixos-generate-config.enable = true;

  fonts.fontconfig.enable = false;

  # Hosts never build, so they don't need their own copy of nixpkgs.
  nixpkgs.flake = {
    setNixPath = false;
    setFlakeRegistry = false;
  };
}
