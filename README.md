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
| `scripts/`       | Hyper-V and WSL network and VM setup                   |
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
| `just route`                           | Add WSL routes to the lab networks           |
| `just hardware-config <host> [target]` | Fetch a host's generated hardware config     |
| `just clean`                           | Remove `result` links and garbage collect    |

`target` defaults to `captain@nix-<host>`, so a deploy can't reach a Debian VM
through an SSH alias named `tcyclops` or `dcyclops`. Flakes only see files tracked
by git, so `git add` new files before building.

Deploy changes to a VM first, then to the server:

```bash
just deploy tcyclops
```

```bash
just deploy cyclops
```

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
| `10.0.3.0/24`    | dcyclops (dev, `.2`)  | Hyper-V **NixHomelabDev** internal vSwitch |
| `10.0.4.0/24`    | tcyclops (test, `.2`) | Hyper-V **NixHomelab** internal vSwitch |
| `192.168.2.0/24` | cyclops (production)  | Physical homelab LAN behind the host    |

The Debian lab uses `10.0.1.0/24` and `10.0.2.0/24`. Both labs reach the internet
through its `HomelabNAT` on `10.0.0.0/16`, because Windows supports only one NAT
per host. The scripts here never create, change or remove that NAT, so it must
already exist. Each host holds the `.1` address of its VM's subnet as the gateway,
and the VMs use static addresses because internal switches have no DHCP.

After a WSL restart, re-run these two steps. The first is in an elevated
PowerShell, because Windows resets forwarding on the WSL adapter:

```powershell
.\scripts\hyper-v\enable-interface-forwarding.ps1
```

```bash
just route
```

Then name the machines in `~/.ssh/config` in WSL, so that `just deploy <host>`
finds them. Use your server's real address for `cyclops`:

```text
Host nix-dcyclops
  HostName 10.0.3.2

Host nix-tcyclops
  HostName 10.0.4.2

Host nix-cyclops
  HostName 192.168.2.2
```

Rebuilding `dcyclops` changes its SSH host key, so clear the old one with
`ssh-keygen -R 10.0.3.2`.

## Setting up the VMs

Do this once per VM. Add your SSH public key to `openssh.authorizedKeys.keys` in
`modules/nixos/common.nix` first: the flake won't evaluate without it, because
password and root SSH logins are disabled, and the ISO installs that key.

1. Build the ISO somewhere Windows can read it:

   ```bash
   just iso tcyclops /mnt/e/isos
   ```

2. Create and start the VM in an elevated PowerShell:

   ```powershell
   .\scripts\hyper-v\create-nix-vm.ps1 -VM tcyclops -IsoPath E:\isos\tcyclops-nix-auto.iso -Start
   ```

   The ISO **wipes the disk with no prompt**, then reboots into the installed
   system. It only checks that it's running under Hyper-V, not which VM it's in,
   so it would also wipe a Debian VM. Only attach it to its own VM.

3. Enable forwarding on the new switches and add the WSL routes, as described in
   [Networking](#networking).

Deploy later changes with `just deploy <vm>`. The ISO contains the system as it
was when built, and a deploy updates it from there.

To throw away `dcyclops` and start again, which is refused for `tcyclops`:

```powershell
.\scripts\hyper-v\create-nix-vm.ps1 -VM dcyclops -IsoPath E:\isos\dcyclops-nix-auto.iso -Rebuild -Start
```

## Setting up the server

1. Install NixOS on `cyclops` with a UEFI boot setup.

2. Let WSL deploy to it. Add this to `/etc/nixos/configuration.nix` on the server,
   with your key, then run `sudo nixos-rebuild switch` there:

   ```nix
   services.openssh.enable = true;
   nix.settings.trusted-users = [ "captain" ];
   security.sudo.wheelNeedsPassword = false;
   users.users.captain = {
     isNormalUser = true;
     extraGroups = [ "wheel" ];
     openssh.authorizedKeys.keys = [ "ssh-ed25519 AAAA... you@wsl" ];
   };
   ```

3. From WSL, replace the placeholder hardware config. `just deploy` refuses to run
   until you do:

   ```bash
   just hardware-config cyclops
   ```

4. Set `system.stateVersion` in `hosts/cyclops/configuration.nix` to the release
   you installed, and `git add` the changes.

5. Deploy:

   ```bash
   just deploy cyclops
   ```
