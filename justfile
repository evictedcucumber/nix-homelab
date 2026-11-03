ssh_user := "captain"

# Keep host keys in the repo, so deploying leaves ~/.ssh on this machine untouched
export NIX_SSHOPTS := "-o UserKnownHostsFile=" + justfile_directory() + "/.known_hosts"

iso_dir := "/mnt/e/isos"
powershell := "/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe"
elevated := powershell + ' -NoProfile -ExecutionPolicy Bypass -File "$(wslpath -wa scripts/hyper-v/run-elevated.ps1)"'

# List available recipes
default:
    @just --list

# Format all files
fmt:
    nix fmt

# Run the pre-commit hook's checks on every file, without committing
pre-commit:
    lefthook run pre-commit --all-files

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
deploy host target=(ssh_user + "@" + if host == "dcyclops" { "10.0.3.2" } else if host == "tcyclops" { "10.0.4.2" } else { error("pass a target: just <recipe> " + host + " " + ssh_user + "@<address>") }): (_require-hardware-config host)
    nixos-rebuild switch --flake .#{{ host }} --target-host {{ target }} --sudo

# Activate on the remote host until its next reboot, to try a risky change
deploy-test host target=(ssh_user + "@" + if host == "dcyclops" { "10.0.3.2" } else if host == "tcyclops" { "10.0.4.2" } else { error("pass a target: just <recipe> " + host + " " + ssh_user + "@<address>") }): (_require-hardware-config host)
    nixos-rebuild test --flake .#{{ host }} --target-host {{ target }} --sudo

# Build a VM's unattended-install ISO into out; booting it wipes the VM's disk
iso host out=".":
    nix build .#{{ host }}-iso --out-link result-{{ host }}-iso
    install -D -m 644 result-{{ host }}-iso/iso/*.iso {{ out }}/{{ host }}-nix-auto.iso

# Build a VM's ISO, then create and start the VM on Windows, after a UAC prompt
vm-create host *flags: (iso host iso_dir)
    {{ elevated }} "$(wslpath -wa scripts/hyper-v/create-nix-vm.ps1)" -VM {{ host }} -IsoPath "$(wslpath -wa {{ iso_dir }}/{{ host }}-nix-auto.iso)" -Start {{ flags }}

# Throw away dcyclops and reinstall it from a new ISO, after a UAC prompt
vm-rebuild host: (vm-create host "-Rebuild")

# Enable Windows forwarding to the VM networks, after a UAC prompt; re-run after a WSL restart
vm-forwarding *flags:
    {{ elevated }} "$(wslpath -wa scripts/hyper-v/enable-interface-forwarding.ps1)" {{ flags }}

# Replace a host's hardware config with one generated on the target
hardware-config host target:
    ssh $NIX_SSHOPTS {{ target }} nixos-generate-config --show-hardware-config > hosts/{{ host }}/hardware-configuration.nix.tmp
    mv hosts/{{ host }}/hardware-configuration.nix.tmp hosts/{{ host }}/hardware-configuration.nix

# Delete local build result links
clean:
    rm -f result result-*

[private]
_require-hardware-config host:
    @if grep -qs '^# Placeholder' hosts/{{ host }}/hardware-configuration.nix; then echo "hosts/{{ host }} still has the placeholder hardware config: run 'just hardware-config {{ host }} <target>' first" >&2; exit 1; fi
