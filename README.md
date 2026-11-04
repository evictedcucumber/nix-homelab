# nix-homelab

NixOS homelab managed with a Nix flake, and deployed over SSH from WSL.

| Host       | Machine                  | Role                                       |
| ---------- | ------------------------ | ------------------------------------------ |
| `cyclops`  | Physical server          | Production                                 |
| `tcyclops` | Hyper-V VM on the WSL PC | Long-lived test VM                         |
| `dcyclops` | Hyper-V VM on the WSL PC | Throwaway dev VM, rebuilt whenever needed  |

These VMs mirror the Debian `tcyclops` and `dcyclops` from the `homelab` repo and
run alongside them. Only the short host names match:

| Debian lab                   | This repo                        |
| ---------------------------- | -------------------------------- |
| `tcyclops.homelab.zezura.cc` | `tcyclops.nix.homelab.zezura.cc` |
| `dcyclops.homelab.zezura.cc` | `dcyclops.nix.homelab.zezura.cc` |

## Layout

| Path             | Purpose                                                |
| ---------------- | ------------------------------------------------------ |
| `flake.nix`      | Hosts, install ISOs, dev shell, formatter and checks   |
| `hosts/<name>/`  | Per-host configuration                                 |
| `modules/nixos/` | Config shared between hosts, and the unattended installer |
| `scripts/`       | Hyper-V network and VM setup                           |
| `treefmt.nix`    | Formatters and linters run by `nix fmt`                |
| `justfile`       | Common commands                                        |

## Development

Enter the dev shell, which provides `just`, `lefthook`, `nixos-rebuild`, the `nixd`
language server and the formatters, and installs the Git pre-commit hook:

```bash
nix develop
```

With [direnv](https://direnv.net), run `direnv allow` once and it loads
automatically.

Run `just` to list the recipes:

| Recipe                                 | What it does                                 |
| -------------------------------------- | -------------------------------------------- |
| `just fmt`                             | Format and lint with nixfmt, deadnix, statix |
| `just pre-commit`                      | Run the pre-commit checks on every file      |
| `just check`                           | Evaluate every host and check formatting     |
| `just update [input]`                  | Update flake inputs                          |
| `just build <host>`                    | Build a host's system without activating it  |
| `just deploy <host> [target]`          | Build in WSL and activate on the host        |
| `just deploy-test <host> [target]`     | Same, but revert on the host's next reboot   |
| `just iso <vm> [dir]`                  | Build a VM's unattended-install ISO          |
| `just vm-create <vm> [flags]`          | Build a VM's ISO, then create and start it   |
| `just vm-rebuild <vm>`                 | Recreate `dcyclops` from a new ISO           |
| `just vm-forwarding [flags]`           | Enable Windows forwarding to the VM networks |
| `just hardware-config <host> <target>` | Fetch a host's generated hardware config     |
| `just clean`                           | Remove `result` links                        |

`target` defaults to the VM's address, and `cyclops` must be given one. Flakes only
see files tracked by git, so `git add` new files before building.

Deploy changes to a VM first, then to the server:

```bash
just deploy tcyclops
```

```bash
just deploy cyclops captain@<address>
```

Deploys ask for `captain`'s sudo password on the target.

The pre-commit hook checks the staged files with the same formatters and linters
as `just fmt`. It rejects the commit if anything fails. If a formatter rewrites a
file, `git add` it and commit again.

## Packages from stable

Everything comes from `nixos-unstable`. When a package is broken there, take that
one package from `nixos-26.05` instead:

```nix
environment.systemPackages = [ pkgs.stable.somePackage ];
```

Stable is only evaluated when something uses it. When a new NixOS release comes
out, update the `nixpkgs-stable` URL in `flake.nix`.

## Networking

| Network          | Host                  | Path                                    |
| ---------------- | --------------------- | --------------------------------------- |
| `172.16.0.0/24`  | tcyclops (test, `.2`) | Hyper-V **NixHomelab** internal vSwitch |
| `172.16.1.0/24`  | dcyclops (dev, `.2`)  | Hyper-V **NixHomelabDev** internal vSwitch |
| TBD              | cyclops (production)  | Physical homelab LAN behind the host    |

Both VMs reach the internet through `NixHomelabNAT` on `172.16.0.0/16`, which
`just vm-create` creates if it's missing. The Debian lab stays on `10.0.1.0/24` and
`10.0.2.0/24` behind its own `HomelabNAT` on `10.0.0.0/16`, and the scripts here never
change or remove any NAT. Each host holds the `.1` address of its VM's subnet as the
gateway, and the VMs use static addresses because internal switches have no DHCP.

Microsoft [supports only one NAT per host](https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/setup-nat-network),
and warns that creating more leaves the system in an unknown state. Running both labs
is therefore unsupported, and `just vm-create` warns when it finds another NAT. If VM
networking misbehaves with both in place, check `Get-NetNat` first. `just vm-create`
also stops if another adapter has an address in `172.16.0.0/16`, because Windows picks
the WSL and Default Switch subnets from the same private range.

Nothing here changes WSL itself. Its default route already goes through Windows,
so it needs no routes of its own. `just` uses addresses directly, so it needs no
SSH config. It keeps host keys in `~/.ssh/known_hosts.d/`, one file per address, and
never touches `~/.ssh/known_hosts`. Builds only add to WSL's Nix store, and every
deploy activates on its target.

After a WSL restart, re-run this, because Windows resets forwarding on the WSL
adapter:

```bash
just vm-forwarding
```

`just` trusts a host's key the first time it connects, and refuses it if it later
changes. Reinstalling a VM changes its key, so `just vm-create` and `just vm-rebuild`
remove the old one.

## Users

| User      | UID and GID | Sudo               | Login                               |
| --------- | ----------- | ------------------ | ----------------------------------- |
| `captain` | 1000        | Yes, with password | SSH key, or password at the console |
| `riley`   | 2000        | No                 | Password at the console only        |

`root` still exists, because NixOS needs it, but every activation locks its password
and its SSH login is off. Use `sudo` from `captain` instead. Emergency mode needs the
root password, so it won't open. To recover from a bad deploy, boot an earlier
generation from the boot menu.

## Setting up the VMs

Do this once per VM. The ISO installs the SSH key from
`modules/nixos/common.nix`, which is the only way in over SSH, because password and
root SSH logins are disabled. It also sets the user passwords below, for logging
in at the VM's console.

1. Build the ISO, then create and start the VM. Run this from WSL and approve the
   UAC prompt, because the scripts in `scripts/hyper-v/` need administrator rights:

   ```bash
   just vm-create tcyclops
   ```

   Each VM is Generation 2, with nested virtualization and every integration
   service on, and the guest runs the Hyper-V daemons. The script stops if any of
   that isn't in place.

   The ISO goes in your Windows Downloads folder. The VM's disks, configuration and
   checkpoints all go in its folder under `E:\Hyper-V VMs`, and the script stops if
   an existing VM has any of them elsewhere.
   To put the ISO elsewhere on a Windows drive, run
   `just iso_dir=/mnt/e/isos vm-create tcyclops`. Pass
   `-Force` or `-Reinstall` after the VM name to use those script options.

   The ISO **wipes the disk with no prompt**, then reboots into the installed
   system. It only checks that it's running under Hyper-V, not which VM it's in,
   so it would also wipe a Debian VM. Only attach it to its own VM.

2. Enable forwarding on the new switches:

   ```bash
   just vm-forwarding
   ```

3. **Change both passwords after first boot.** `captain` and `riley` both start with
   the password `PleaseChangeMe1`, which is in this repo and readable by anyone on the
   VM through the Nix store:

   ```bash
   ssh -t -o UserKnownHostsFile=~/.ssh/known_hosts.d/172.16.0.2 captain@172.16.0.2 'passwd && sudo passwd riley'
   ```

   Use `172.16.1.2` for `dcyclops`. New passwords survive deploys, but rebuilding
   `dcyclops` resets them, so change them again after each rebuild.

Deploy later changes with `just deploy <vm>`. The ISO contains the system as it
was when built, and a deploy updates it from there.

To throw away `dcyclops` and start again, which is refused for `tcyclops`:

```bash
just vm-rebuild dcyclops
```

## Setting up the server

1. Install NixOS on `cyclops` with a UEFI boot setup.

2. Let WSL deploy to it. Add this to `/etc/nixos/configuration.nix` on the server,
   then run `sudo nixos-rebuild switch` there:

   ```nix
   services.openssh.enable = true;
   nix.settings.trusted-users = [ "captain" ];
   users.users.captain = {
     isNormalUser = true;
     extraGroups = [ "wheel" ];
     initialPassword = "PleaseChangeMe1";
     openssh.authorizedKeys.keys = [ "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJGshhca+nI1Qt1zDNvHCYIokESlCHMi+0JjvcdW7+3F nix-homelab-control-node" ];
   };
   ```

3. From WSL, replace the placeholder hardware config. `just deploy` refuses to run
   until you do:

   ```bash
   just hardware-config cyclops captain@<address>
   ```

4. Set `system.stateVersion` in `hosts/cyclops/configuration.nix` to the release
   you installed, and `git add` the changes.

5. Deploy. This creates `riley` with the password `PleaseChangeMe1` and locks `root`.
   It leaves the password of the existing `captain` user alone:

   ```bash
   just deploy cyclops captain@<address>
   ```

6. Change the passwords:

   ```bash
   ssh -t -o UserKnownHostsFile=~/.ssh/known_hosts.d/<address> captain@<address> 'passwd && sudo passwd riley'
   ```
