# nix-homelab

Basic nix flake project used to build and deploy a NixOS homelab.

## Build

```bash
nix build .#nixosConfigurations.homelab.config.system.build.toplevel
```

## Deploy

```bash
sudo nixos-rebuild switch --flake .#homelab
```
