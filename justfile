# The user when a target is only an address, because it has sudo
ssh_user := "captain"
ssh_key := "~/.ssh/nix-homelab-control-node.key"

# Offer only the control node's key. Keep host keys in their own directory, one file per
# address, so ~/.ssh/known_hosts is left untouched. A key is trusted the first time, and a
# later change is refused.
export NIX_SSHOPTS := "-i " + ssh_key + " -o IdentitiesOnly=yes -o UserKnownHostsFile=~/.ssh/known_hosts.d/%h -o StrictHostKeyChecking=accept-new"

powershell := "/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe"

# Where ISOs go, or empty for the Windows Downloads folder
iso_dir := ""

# A command rather than a value, so only the recipes that need it start PowerShell
downloads := 'p="$(' + powershell + " -NoProfile -NonInteractive -Command \"(New-Object -ComObject Shell.Application).Namespace('shell:Downloads').Self.Path\" | tr -d '\\r')\" && [ -n \"$p\" ] && wslpath -u \"$p\""
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
deploy host target=(if host == "dcyclops" { "172.16.1.2" } else if host == "tcyclops" { "172.16.0.2" } else { error("pass a target: just <recipe> " + host + " <address>") }): (_require-hardware-config host) _known-hosts-dir
    nixos-rebuild switch --flake .#{{ host }} --target-host {{ if target =~ "@" { target } else { ssh_user + "@" + target } }} --ask-elevate-password

# Activate on the remote host until its next reboot, to try a risky change
deploy-test host target=(if host == "dcyclops" { "172.16.1.2" } else if host == "tcyclops" { "172.16.0.2" } else { error("pass a target: just <recipe> " + host + " <address>") }): (_require-hardware-config host) _known-hosts-dir
    nixos-rebuild test --flake .#{{ host }} --target-host {{ if target =~ "@" { target } else { ssh_user + "@" + target } }} --ask-elevate-password

# Reboot the host, which also drops a deploy-test
reboot host target=(if host == "dcyclops" { "172.16.1.2" } else if host == "tcyclops" { "172.16.0.2" } else { error("pass a target: just <recipe> " + host + " <address>") }): _known-hosts-dir
    ssh -t $NIX_SSHOPTS {{ if target =~ "@" { target } else { ssh_user + "@" + target } }} sudo systemctl reboot

# Build a VM's unattended-install ISO into out, by default Windows Downloads; booting it wipes the VM's disk
iso host out=iso_dir:
    nix build .#{{ host }}-iso --out-link result-{{ host }}-iso
    dir="{{ out }}"; dir="${dir:-$({{ downloads }})}" && install -D -m 644 result-{{ host }}-iso/iso/*.iso "$dir/{{ host }}-nix-auto.iso"

# Build a VM's ISO, create and start the VM on Windows after a UAC prompt, and forget its old host key
vm-create host *flags: (iso host iso_dir) _known-hosts-dir
    dir="{{ iso_dir }}"; dir="${dir:-$({{ downloads }})}" && {{ elevated }} "$(wslpath -wa scripts/hyper-v/create-nix-vm.ps1)" -VM {{ host }} -IsoPath "$(wslpath -wa "$dir/{{ host }}-nix-auto.iso")" -Start {{ flags }}
    rm -f ~/.ssh/known_hosts.d/{{ if host == "dcyclops" { "172.16.1.2" } else { "172.16.0.2" } }}

# Throw away dcyclops and reinstall it from a new ISO, after a UAC prompt
vm-rebuild host: (vm-create host "-Rebuild")

# Enable Windows forwarding to the VM networks, after a UAC prompt; re-run after a WSL restart
vm-forwarding *flags:
    {{ elevated }} "$(wslpath -wa scripts/hyper-v/enable-interface-forwarding.ps1)" {{ flags }}

# Replace a host's hardware config with one generated on the target
hardware-config host target: _known-hosts-dir
    ssh $NIX_SSHOPTS {{ if target =~ "@" { target } else { ssh_user + "@" + target } }} nixos-generate-config --show-hardware-config > hosts/{{ host }}/hardware-configuration.nix.tmp
    mv hosts/{{ host }}/hardware-configuration.nix.tmp hosts/{{ host }}/hardware-configuration.nix

# Delete local build result links
clean:
    rm -f result result-*

[private]
_known-hosts-dir:
    @mkdir -p ~/.ssh/known_hosts.d

[private]
_require-hardware-config host:
    @if grep -qs '^# Placeholder' hosts/{{ host }}/hardware-configuration.nix; then echo "hosts/{{ host }} still has the placeholder hardware config: run 'just hardware-config {{ host }} <target>' first" >&2; exit 1; fi
