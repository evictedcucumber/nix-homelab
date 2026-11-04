{
  description = "NixOS homelab managed with a Nix flake";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    # Fallback for packages broken on unstable, used as `pkgs.stable.<name>`.
    nixpkgs-stable.url = "github:NixOS/nixpkgs/nixos-26.05";

    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      nixpkgs-stable,
      disko,
      treefmt-nix,
    }:
    let
      vmHosts = [
        "dcyclops"
        "tcyclops"
      ];

      mkHost =
        name:
        nixpkgs.lib.nixosSystem {
          modules = [
            {
              networking.hostName = name;
              nixpkgs.overlays = [ self.overlays.stable ];
            }
            disko.nixosModules.disko
            ./modules/nixos/common.nix
            ./modules/nixos/dns.nix
            ./modules/nixos/firewall.nix
            ./modules/nixos/hardening.nix
            ./modules/nixos/minimal.nix
            ./hosts/${name}/configuration.nix
          ];
        };

      mkInstallerIso =
        name:
        let
          installer = nixpkgs.lib.nixosSystem {
            modules = [
              "${nixpkgs}/nixos/modules/installer/cd-dvd/installation-cd-minimal.nix"
              (import ./modules/nixos/auto-installer.nix { target = self.nixosConfigurations.${name}; })
            ];
          };
        in
        {
          name = "${name}-iso";
          value = installer.config.system.build.isoImage;
        };

      forAllSystems =
        f:
        nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ] (
          system:
          let
            pkgs = nixpkgs.legacyPackages.${system};
          in
          f {
            inherit pkgs;
            treefmt = treefmt-nix.lib.evalModule pkgs ./treefmt.nix;
          }
        );
    in
    {
      nixosConfigurations = nixpkgs.lib.genAttrs ([ "cyclops" ] ++ vmHosts) mkHost;

      packages.x86_64-linux = builtins.listToAttrs (map mkInstallerIso vmHosts);

      overlays.stable = final: _: {
        stable = import nixpkgs-stable {
          inherit (final.stdenv.hostPlatform) system;
          config.allowUnfree = final.config.allowUnfree;
        };
      };

      formatter = forAllSystems ({ treefmt, ... }: treefmt.config.build.wrapper);

      checks = forAllSystems (
        { treefmt, ... }:
        {
          formatting = treefmt.config.build.check self;
        }
      );

      devShells = forAllSystems (
        { pkgs, treefmt }:
        {
          default = pkgs.mkShellNoCC {
            packages = [
              pkgs.just
              pkgs.lefthook
              pkgs.nixd
              pkgs.nixos-rebuild
              treefmt.config.build.wrapper
            ];
            shellHook = "lefthook install > /dev/null";
          };
        }
      );
    };
}
