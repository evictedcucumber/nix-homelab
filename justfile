# The user recipes log in as on a host, because it has sudo
ssh_user := "captain"
ssh_key := "~/.ssh/nix-homelab-control-node.key"
export DEPLOY_USER := ssh_user
signing_key := "~/.config/nix-homelab/signing.key"

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

# Run the tests a change since main can affect, or only the ones named
test *names:
    scripts/test.sh {{ names }}

# Update all flake inputs, or only the one named
update input="":
    nix flake update {{ input }}

# Build a host's system closure without activating it
build host:
    nix build .#nixosConfigurations.{{ host }}.config.system.build.toplevel

# Build locally, sign, copy and activate on the remote host, then offer a reboot if it needs one
deploy host: (_require-hardware-config host) _known-hosts-dir && (_offer-reboot host)
    scripts/deploy.sh switch {{ host }}

# Activate on the remote host until its next reboot, to try a risky change
deploy-test host: (_require-hardware-config host) _known-hosts-dir
    scripts/deploy.sh test {{ host }}

# Print a host's ntfy certificate (PEM), to import into the phone. Public, but root-only on the host
ntfy-cert host: _known-hosts-dir
    #!/usr/bin/env bash
    set -euo pipefail
    echo "Type {{ ssh_user }}'s sudo password on {{ host }}; nothing is shown while you do" >&2
    address=$(scripts/deploy.sh address {{ host }})
    cert=$(ssh -t $NIX_SSHOPTS "{{ ssh_user }}@$address" sudo cat /var/lib/nixos-containers/ntfy/var/lib/private/ntfy-sh/tls.crt | tr -d '\r')
    pem=$(sed -n '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/p' <<< "$cert")
    [ -n "$pem" ] || { echo "No certificate from {{ host }}: has ntfy started?" >&2; exit 1; }
    printf '%s\n' "$pem"

# Reboot the host, which also drops a deploy-test
reboot host: _known-hosts-dir
    address=$(scripts/deploy.sh address {{ host }}) && ssh -t $NIX_SSHOPTS "{{ ssh_user }}@$address" sudo systemctl reboot

# Build a VM's unattended-install ISO into out, by default Windows Downloads; booting it wipes the VM's disk
iso host out=iso_dir:
    nix build .#{{ host }}-iso --out-link result-{{ host }}-iso
    dir="{{ out }}"; dir="${dir:-$({{ downloads }})}" && install -D -m 644 result-{{ host }}-iso/iso/*.iso "$dir/{{ host }}-nix-auto.iso"

# Build a VM's ISO, create and start the VM on Windows after a UAC prompt, and forget its old host key
vm-create host *flags: (iso host iso_dir) _known-hosts-dir
    dir="{{ iso_dir }}"; dir="${dir:-$({{ downloads }})}" && {{ elevated }} "$(wslpath -wa scripts/hyper-v/create-nix-vm.ps1)" -VM {{ host }} -IsoPath "$(wslpath -wa "$dir/{{ host }}-nix-auto.iso")" -Start {{ flags }}
    rm -f ~/.ssh/known_hosts.d/"$(scripts/deploy.sh address {{ host }})"
    @echo "{{ host }} has a new SSH host key, so it can't decrypt its secrets yet. Once it has booted, run 'just secrets-rekey {{ host }}' and then 'just deploy {{ host }}'."

# Throw away dcyclops and reinstall it from a new ISO, after a UAC prompt
vm-rebuild host: (vm-create host "-Rebuild")

# Create and start the throwaway desktop VM, or destroy it with its disk and ISO, after a UAC prompt
[arg("action", pattern="create|destroy")]
vm-dev action:
    @{{ just_executable() }} iso_dir="{{ iso_dir }}" _vm-dev-{{ action }}

# Enable Windows forwarding to the VM networks, after a UAC prompt; re-run after a WSL restart
vm-forwarding *flags:
    {{ elevated }} "$(wslpath -wa scripts/hyper-v/enable-interface-forwarding.ps1)" {{ flags }}

# Replace a host's hardware config with one generated on the host
hardware-config host: _known-hosts-dir
    address=$(scripts/deploy.sh address {{ host }}) && ssh $NIX_SSHOPTS "{{ ssh_user }}@$address" nixos-generate-config --show-hardware-config > hosts/{{ host }}/hardware-configuration.nix.tmp
    mv hosts/{{ host }}/hardware-configuration.nix.tmp hosts/{{ host }}/hardware-configuration.nix

# Create the deploy signing key if missing, and write its public half to keys/
signing-key:
    #!/usr/bin/env bash
    set -euo pipefail
    key={{ signing_key }}
    if [ ! -e "$key" ]; then
        mkdir -p -m 700 "$(dirname "$key")"
        (umask 077 && nix key generate-secret --key-name nix-homelab-1 > "$key")
        echo "Created $key. Back it up: see manual-setup.md."
    fi
    nix key convert-secret-to-public < "$key" > keys/nix-homelab-signing.pub

# Scan a host's closure for known CVEs, built on this machine. Exit 2 means findings.
vulnix host:
    #!/usr/bin/env bash
    set -euo pipefail
    out=$(nix build --no-link --print-out-paths .#nixosConfigurations.{{ host }}.config.system.build.toplevel)
    rc=0
    vulnix --closure --whitelist vulnix-whitelist.toml "$out" || rc=$?
    if [ "$rc" = 2 ]; then
        echo "vulnix: vulnerabilities reported above (exit 2); whitelist accepted ones in vulnix-whitelist.toml." >&2
    fi
    exit "$rc"

# Create secrets/<host>.yaml with new random passwords, encrypted for the admin key; never overwrites
secrets-init host:
    scripts/secrets.sh init {{ host }}

# Encrypt a host's secrets for its current SSH host key, fetched over SSH, so it can decrypt them after a reinstall
secrets-rekey host: _known-hosts-dir
    address=$(scripts/deploy.sh address {{ host }}) && scripts/secrets.sh rekey {{ host }} "$address"

# Ask for a login password twice, then write its yescrypt hash to users/<user>.hash for the repo
[arg("user", pattern="[a-z][a-z0-9_-]*")]
set-password user:
    #!/usr/bin/env bash
    set -euo pipefail
    read -r -s -p "New password for {{ user }}: " first; echo
    read -r -s -p "Repeat it: " second; echo
    [ "$first" = "$second" ] || { echo "The passwords differ" >&2; exit 1; }
    # What the hosts' pwquality asks of passwords, which a hash from the repo skips.
    if [ "${#first}" -lt 15 ] || [[ ! $first =~ [A-Z] ]] || [[ ! $first =~ [a-z] ]] || [[ ! $first =~ [0-9] ]] || [[ ! $first =~ [^A-Za-z0-9] ]]; then
        echo "Use at least 15 characters with upper and lower case, a digit and a symbol: the hash is public, so only the password protects it" >&2
        exit 1
    fi
    mkdir -p users
    printf %s "$first" | mkpasswd --method=yescrypt --stdin > users/{{ user }}.hash.tmp
    mv users/{{ user }}.hash.tmp users/{{ user }}.hash
    echo "Wrote users/{{ user }}.hash. Run 'git add users/{{ user }}.hash' (flakes only see tracked files), commit it, then deploy to apply it."

# Delete local build result links
clean:
    rm -f result result-*

[private]
_vm-dev-create: (iso "vm-dev" iso_dir)
    dir="{{ iso_dir }}"; dir="${dir:-$({{ downloads }})}" && {{ elevated }} "$(wslpath -wa scripts/hyper-v/create-nix-vm.ps1)" -VM vm-dev -IsoPath "$(wslpath -wa "$dir/vm-dev-nix-auto.iso")" -Start

[private]
_vm-dev-destroy:
    {{ elevated }} "$(wslpath -wa scripts/hyper-v/create-nix-vm.ps1)" -VM vm-dev -Destroy
    dir="{{ iso_dir }}"; dir="${dir:-$({{ downloads }})}" && rm -f "$dir/vm-dev-nix-auto.iso"
    rm -f result-vm-dev-iso

# Only a new kernel, initrd, or kernel modules can't be activated by a switch
[private]
_offer-reboot host:
    #!/usr/bin/env bash
    set -u
    address=$(scripts/deploy.sh address {{ host }}) || exit 0
    status=0
    ssh -n $NIX_SSHOPTS "{{ ssh_user }}@$address" 'for p in initrd kernel kernel-modules; do [ "$(readlink /run/booted-system/$p)" = "$(readlink /run/current-system/$p)" ] || exit 10; done' || status=$?
    case "$status" in
        0) exit 0 ;;
        10) ;;
        *) echo "Could not tell whether {{ host }} needs a reboot" >&2; exit 0 ;;
    esac
    read -r -p "{{ host }} needs a reboot for its new kernel or initrd. Reboot now? [y/N] " answer || answer=n
    case "$answer" in
        [yY] | [yY][eE][sS]) exec {{ just_executable() }} reboot {{ host }} ;;
        *) echo "Skipped. Run 'just reboot {{ host }}' when ready." ;;
    esac

[private]
_known-hosts-dir:
    @mkdir -p ~/.ssh/known_hosts.d

[private]
_require-hardware-config host:
    @if grep -qs '^# Placeholder' hosts/{{ host }}/hardware-configuration.nix; then echo "hosts/{{ host }} still has the placeholder hardware config: run 'just hardware-config {{ host }}' first" >&2; exit 1; fi
