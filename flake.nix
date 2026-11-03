{
  description = "Basic Nix flake for homelab NixOS deployment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { nixpkgs, ... }: {
    nixosConfigurations.homelab = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        ./hosts/homelab/configuration.nix
        ./hosts/homelab/hardware-configuration.nix
      ];
    };
  };
}
