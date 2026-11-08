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

    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Hosts can't download lists, so the blocklist arrives with each deploy.
    blocklist = {
      url = "git+https://github.com/zachlagden/Pi-hole-Optimized-Blocklists?lfs=1&shallow=1";
      flake = false;
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      nixpkgs-stable,
      disko,
      home-manager,
      treefmt-nix,
      sops-nix,
      blocklist,
    }:
    let
      vmHosts = [
        "dcyclops"
        "tcyclops"
      ];

      hostModules = name: [
        {
          networking.hostName = name;
          nixpkgs.overlays = [ self.overlays.stable ];
        }
        disko.nixosModules.disko
        home-manager.nixosModules.home-manager
        sops-nix.nixosModules.sops
        ./modules/nixos
        ./modules/containers
        ./hosts/${name}/configuration.nix
      ];

      mkHost =
        name:
        nixpkgs.lib.nixosSystem {
          specialArgs = { inherit blocklist; };
          modules = hostModules name;
        };

      # Not a managed server, so it leaves out the modules every host shares.
      vmDev = nixpkgs.lib.nixosSystem {
        modules = [
          { networking.hostName = "vm-dev"; }
          disko.nixosModules.disko
          ./hosts/vm-dev/configuration.nix
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
      nixosConfigurations = nixpkgs.lib.genAttrs vmHosts mkHost // {
        vm-dev = vmDev;
      };

      packages.x86_64-linux = builtins.listToAttrs (map mkInstallerIso (vmHosts ++ [ "vm-dev" ]));

      # Not checks, because `nix flake check` would then need uid-range. `just test` runs these.
      legacyPackages.x86_64-linux.tests = import ./tests {
        inherit blocklist hostModules sops-nix;
        pkgs = nixpkgs.legacyPackages.x86_64-linux;
      };

      overlays.stable = final: _: {
        stable = import nixpkgs-stable {
          inherit (final.stdenv.hostPlatform) system;
          config.allowUnfree = final.config.allowUnfree;
        };
      };

      formatter = forAllSystems ({ treefmt, ... }: treefmt.config.build.wrapper);

      checks =
        nixpkgs.lib.recursiveUpdate
          (forAllSystems (
            { treefmt, ... }:
            {
              formatting = treefmt.config.build.check self;
            }
          ))
          {
            x86_64-linux.eval = import ./tests/eval {
              inherit (nixpkgs) lib;
              pkgs = nixpkgs.legacyPackages.x86_64-linux;
              hosts = self.nixosConfigurations;
            };
          };

      devShells = forAllSystems (
        { pkgs, treefmt }:
        {
          default = pkgs.mkShellNoCC {
            packages = [
              pkgs.age
              pkgs.just
              pkgs.lefthook
              pkgs.mkpasswd
              pkgs.nixd
              pkgs.nixos-rebuild
              pkgs.sops
              pkgs.ssh-to-age
              pkgs.vulnix
              pkgs.yq-go
              treefmt.config.build.wrapper
            ];
            shellHook = "lefthook install > /dev/null";
          };
        }
      );
    };
}
