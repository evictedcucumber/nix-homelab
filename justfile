ssh_user := "captain"

# List available recipes
default:
    @just --list

# Format all files
fmt:
    nix fmt

# Evaluate every host and run the flake checks
check:
    nix flake check

# Update all flake inputs, or only the one named
update input="":
    nix flake update {{ input }}

# Build a host's system closure without activating it
build host:
    nix build .#nixosConfigurations.{{ host }}.config.system.build.toplevel

# Build locally, then activate on the remote host
deploy host target=(ssh_user + "@nix-" + host): (_require-hardware-config host)
    nixos-rebuild switch --flake .#{{ host }} --target-host {{ target }} --sudo

# Activate on the remote host until its next reboot, to try a risky change
deploy-test host target=(ssh_user + "@nix-" + host): (_require-hardware-config host)
    nixos-rebuild test --flake .#{{ host }} --target-host {{ target }} --sudo

# Build a VM's unattended-install ISO into out; booting it wipes the VM's disk
iso host out=".":
    nix build .#{{ host }}-iso --out-link result-{{ host }}-iso
    install -m 644 result-{{ host }}-iso/iso/*.iso {{ out }}/{{ host }}-nix-auto.iso

# Add WSL routes to the VM networks and the homelab LAN; re-run after a WSL restart
route:
    scripts/wsl/route-nix-vms.sh

# Replace a host's hardware config with one generated on the target
hardware-config host target=(ssh_user + "@nix-" + host):
    ssh {{ target }} nixos-generate-config --show-hardware-config > hosts/{{ host }}/hardware-configuration.nix.tmp
    mv hosts/{{ host }}/hardware-configuration.nix.tmp hosts/{{ host }}/hardware-configuration.nix

# Delete old local build results and garbage collect the local store
clean:
    rm -f result result-*
    nix store gc

[private]
_require-hardware-config host:
    @if grep -qs '^# Placeholder' hosts/{{ host }}/hardware-configuration.nix; then echo "hosts/{{ host }} still has the placeholder hardware config: run 'just hardware-config {{ host }}' first" >&2; exit 1; fi
