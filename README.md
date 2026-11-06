# nix-homelab

NixOS homelab managed with a Nix flake, and deployed over SSH from WSL.

| Host       | Machine                  | Role                                       |
| ---------- | ------------------------ | ------------------------------------------ |
| `cyclops`  | Physical server          | Production                                 |
| `tcyclops` | Hyper-V VM on the WSL PC | Long-lived test VM                         |
| `dcyclops` | Hyper-V VM on the WSL PC | Throwaway dev VM, rebuilt whenever needed  |
| `vm-dev`   | Hyper-V VM on the WSL PC | Temporary desktop for testing `dcyclops`   |

These VMs mirror the Debian `tcyclops` and `dcyclops` from the `homelab` repo and
run alongside them. Both labs use the same FQDNs, and only the Hyper-V VM names differ:

| Debian VM name               | Nix VM name                        |
| ---------------------------- | ---------------------------------- |
| `tcyclops.homelab.zezura.cc` | `[nix] tcyclops.homelab.zezura.cc` |
| `dcyclops.homelab.zezura.cc` | `[nix] dcyclops.homelab.zezura.cc` |

## Layout

| Path             | Purpose                                                |
| ---------------- | ------------------------------------------------------ |
| `flake.nix`      | Hosts, install ISOs, dev shell, formatter and checks   |
| `hosts/<name>/`  | Per-host configuration                                 |
| `modules/nixos/` | Config shared between hosts, and the unattended installer |
| `home/`          | Home Manager config for each user                      |
| `scripts/`       | Hyper-V network and VM setup, and the test runner      |
| `tests/`         | NixOS tests, run by `just test`                        |
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
| `just test [names]`                    | Run the tests a change can affect            |
| `just update [input]`                  | Update flake inputs                          |
| `just build <host>`                    | Build a host's system without activating it  |
| `just deploy <host> [target]`          | Build and activate, offering a needed reboot |
| `just deploy-test <host> [target]`     | Same, but revert on the host's next reboot   |
| `just reboot <host> [target]`          | Reboot the host, after a `sudo` prompt       |
| `just iso <vm> [dir]`                  | Build a VM's unattended-install ISO          |
| `just vm-create <vm> [flags]`          | Build a VM's ISO, then create and start it   |
| `just vm-rebuild <vm>`                 | Recreate `dcyclops` from a new ISO           |
| `just vm-dev <create\|destroy>`         | Create or remove the throwaway desktop VM    |
| `just vm-forwarding [flags]`           | Enable Windows forwarding to the VM networks |
| `just hardware-config <host> <target>` | Fetch a host's generated hardware config     |
| `just clean`                           | Remove `result` links                        |

`target` defaults to the VM's address, and `cyclops` must be given one. It's an address,
which logs in as `captain`, or `<user>@<address>`. Flakes only see files tracked by git,
so `git add` new files before building.

SSH connections from `just` offer only the private key
`~/.ssh/nix-homelab-control-node.key`, which matches the public key in
`modules/nixos/common.nix`.

Deploy changes to a VM first, then to the server:

```bash
just deploy tcyclops
```

```bash
just deploy cyclops <address>
```

Deploys ask for `captain`'s sudo password on the target. Everything is built in WSL
and pushed over SSH. The hosts set `max-jobs = 0`, so any build started on one fails,
including `nixos-rebuild` or `nix-shell` run there.

The pre-commit hook checks the staged files with the same formatters and linters
as `just fmt`. It rejects the commit if anything fails. If a formatter rewrites a
file, `git add` it and commit again.

## Packages

`modules/nixos/minimal.nix` keeps hosts to a server's package set, using the nixpkgs
minimal profile. Hosts have no man pages or other docs, `git`, `vim`, `htop`, `rsync`,
`strace`, or copy of nixpkgs, and `nano` is the only editor. Of the NixOS tools, only
`nixos-generate-config` stays, for `just hardware-config`. Add a package a host really
needs to `environment.systemPackages`, then deploy it. There's no `nixos-rebuild` on the
hosts, so to go back, boot an earlier generation or deploy an earlier commit.

## Packages from stable

Everything comes from `nixos-unstable`. When a package is broken there, take that
one package from `nixos-26.05` instead:

```nix
environment.systemPackages = [ pkgs.stable.somePackage ];
```

Stable is only evaluated when something uses it. It stays on 26.05 because
`nixos-26.11` has no branch yet. When a new NixOS release comes out, update the
`nixpkgs-stable` URL in `flake.nix`.

## Networking

| Network          | Host                  | Path                                    |
| ---------------- | --------------------- | --------------------------------------- |
| `172.16.0.0/24`  | tcyclops (test, `.2`) | Hyper-V **NixHomelab** internal vSwitch |
| `172.16.1.0/24`  | dcyclops (dev, `.2`)  | Hyper-V **NixHomelabDev** internal vSwitch |
| TBD              | cyclops (production)  | Physical homelab LAN behind the host    |

Both VMs sit behind `NixHomelabNAT` on `172.16.0.0/16`, which
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

SSH only accepts public keys, and only for `captain`. Keys must be set in
`modules/nixos/common.nix`, because `sshd` ignores `~/.ssh/authorized_keys`. Forwarding
and tunnels are off, so `ssh -L`, `-R`, `-D` and `-A` won't work. To give `riley` SSH
access, add a key for that user and add `riley` to `AllowUsers`.

Home Manager manages each user's environment, and deploys with the system. Put settings
for everyone in `home/common.nix`, and for one user in `home/<user>.nix`. Packages in
`home.packages` go to that user only, so use them rather than the system list where you
can. Set `home.stateVersion` once and leave it. A file Home Manager needs to replace is
renamed with `.hm-bak`. If a deploy fails on `home-manager-<user>.service`, check
`journalctl -u home-manager-<user>`. A new user also needs adding to the list in
`modules/nixos/home-manager.nix`.

Activation opens the Nix store read-only, because `riley` isn't allowed to reach the
Nix daemon. An activation step that writes to the store, such as a custom
`home.activation` entry calling `nix-env`, fails there.

`modules/nixos/hardening.nix` applies the Anduril NixOS STIG where it fits this homelab.
`stig-audit.md` lists every finding and why it was adopted or skipped. In day-to-day use:

- Only `root` and `wheel` can use Nix, so `riley` can't.
- New passwords need 15 characters, all four character classes and 8 changed characters,
  and can't be dictionary words. Root only gets a warning, so `sudo passwd` can skip this.
- `sudo` asks for the password every time.
- Three failed console logins in 15 minutes lock an account for 15 minutes.
- More than 30 new SSH connections a minute from one address are dropped.
- USB devices plugged in after boot are blocked until allowed with `usbguard`.
- A weekly AIDE check of `/boot` and `/etc` fails after any deploy. To accept the new
  baseline, delete `/var/lib/aide/aide.db` and the next run recreates it.

`modules/nixos/firewall.nix` drops everything in, out and forwarded except inbound SSH
and outbound NTP, NTS and DNS over TLS, plus their replies. Hosts can't start any other
outbound connection, so everything reaches them by `just deploy` from WSL. IPv6 is off,
and hosts don't answer ping. A host can also connect to its own [containers](#containers),
and forwards inbound DNS and web traffic for one extra address to [Pi-hole](#pi-hole), and
web traffic for another to [Grafana](#logging).

DNS goes from `systemd-resolved` to `dnsdist`, which sends it over TLS to Cloudflare, or
to Quad9 while Cloudflare is down, and returns to Cloudflare when it recovers. There's no
plain DNS fallback, and the firewall blocks outbound port 53. `chrony` uses
`time.cloudflare.com` over NTS.

## Containers

`modules/nixos/containers.nix` sets up
[NixOS containers](https://nixos.org/manual/nixos/stable/#ch-containers). Nothing changes
on a host until it declares one in its `configuration.nix`, which only needs a unique
address in `10.233.0.0/24` (the host is `10.233.0.1`) and a name of up to 11 characters.
Name it after its service: the name is also its hostname, under the host's domain, so
the one below is `web.homelab.zezura.cc` inside the container.

```nix
containers.web = {
  localAddress = "10.233.0.2";
  config = {
    services.nginx.enable = true;
    networking.firewall.allowedTCPPorts = [ 80 ];
  };
};
```

The host's modules don't apply inside a container, so the hardening and SSH settings stop
at the host. Open a shell in one from the host:

```bash
sudo nixos-container root-login web
```

Each container has its own firewall, inside the container, which drops everything in and
out, including DNS. Outbound traffic has to pass both that firewall and the host's, so
allowing something on one side changes nothing until the other allows it too:

| To allow             | In the container's `config`                                  | On the host                                                        |
| -------------------- | ------------------------------------------------------------ | ------------------------------------------------------------------ |
| DNS                  | `containerFirewall.allowDns = true;`                         | Nothing, this opens it there too                                   |
| Outbound connections | `containerFirewall.extraOutputRules = "tcp dport 443 accept";` | `networking.firewall.extraForwardRules = ''iifname "ve-web" tcp dport 443 accept'';` |
| Inbound from the host | `networking.firewall.allowedTCPPorts = [ 80 ];`              | Nothing, the host can connect to its containers                    |

Root in a container can flush that container's firewall, so treat it as policy for what
the container should do, and the host's rules as the limit on a compromised one. The host
always blocks the rest:

- A container's root isn't root on the host, and the host's Nix daemon refuses it.
- A container can't reach other containers, including through their `forwardPorts`, or
  forge its source address.
- A container that hasn't enabled DNS can't reach any port on the host. One that has can
  only reach port 53, and its lookups go over TLS. They do leave the host, so a
  compromised container could still smuggle data out through them.

A host rule like the one in the table also reaches the LAN. Add an `ip daddr` match to
limit it. Assertions stop a host from turning off `privateNetwork` or `privateUsers`, or
giving a container other network interfaces or extra capabilities.

A directory shared with `bindMounts` shows up as unowned, so share a writable one with
`extraFlags = [ "--bind=/host/path:/container/path:idmap" ]` instead.

`forwardPorts` publishes a container's port on every host interface, without an
`allowedTCPPorts` entry on the host, though the container's firewall must still allow it.
Containers are declarative only: `nixos-container create` needs a build, and hosts don't
build.

## Pi-hole

`modules/nixos/pihole.nix` runs Pi-hole on every host, in a container named `pihole` at
`10.233.0.2`. Clients reach it on its own address on the host's network, set with
`pihole.lanAddress`: `172.16.0.3` on `tcyclops` and `172.16.1.3` on `dcyclops`. `cyclops`
has none yet, so nothing outside it can reach Pi-hole there.

| Service | Port |
| --- | --- |
| DNS | 53, UDP and TCP |
| Web interface | 443, with port 80 redirecting to it |

```bash
dig @172.16.0.3 pi.hole
```

The web interface is at `https://172.16.0.3/`, or `https://pi.hole/` for clients using
Pi-hole for DNS. Its certificate is self-signed, so browsers warn about it. The password
is generated when Pi-hole first starts, and stays out of the Nix store. Read it on the
host:

```bash
sudo cat /var/lib/nixos-containers/pihole/var/lib/pihole/web-password.env
```

To change it, edit that file and run
`sudo nixos-container run pihole -- systemctl restart pihole-ftl`. Settings are read-only
in the interface, because they come from this repo.

The address is a second address on the host, not a separate interface, because containers
only get their [`ve-<name>` interface](#containers). The host forwards these ports to the
container and drops everything else sent to the address, so SSH stays on the host's own
address, and Pi-hole doesn't answer on that one.

It starts on boot, and restarts if FTL or the container exits for any reason, until
stopped with `sudo systemctl stop container@pihole`. Check it from the host:

```bash
sudo nixos-container run pihole -- journalctl -u pihole-ftl
```

Pi-hole resolves through the host, so lookups leave over TLS like the host's own. Clients
still talk to it in plain DNS, and only from private addresses (`10.0.0.0/8`,
`172.16.0.0/12` and `192.168.0.0/16`). The host itself keeps using `dnsdist` directly, and
other containers can't reach Pi-hole.

It blocks the domains in
[Pi-hole Optimized Blocklists](https://github.com/zachlagden/Pi-hole-Optimized-Blocklists),
answering `0.0.0.0`. It uses `all_domains.txt`, the largest list, which leaves out adult
sites but can block some legitimate domains. Hosts can't download lists, so the list is a
flake input and arrives with each deploy. It stays as it is until you update it:

```bash
just update blocklist
```

Then run `just deploy <host>`, which reloads it. Lists added in the web interface can't be
downloaded either, for the same reason.

## Logging

`modules/nixos/logging.nix` runs Grafana, Loki and Prometheus on every host, in one container
named `grafana` at `10.233.0.3`, because containers can't reach each other. Alloy runs on the
host and sends its journal to Loki. The journal holds SSH and `sudo` logs, the audit records
and every service's output, and each line is labelled with the host, `unit`, `identifier`,
`transport` and `level`.

Every container in `containers` is picked up with no setup: Alloy also reads each one's journal
from `/var/lib/nixos-containers/<name>/var/log/journal`, labelled with the host and
`container`. The label comes from the config, not from the journal, which the container
controls. Alloy also sends each container's state, restarts and tasks (from `systemd`) and CPU
and memory (from cAdvisor) to Prometheus. Alloy restarts when a container starts with a
journal newer than Alloy, such as on its first start, so it finds the new journal.

Grafana is on its own address on the host's network, set with `logging.lanAddress`:
`172.16.0.4` on `tcyclops` and `172.16.1.4` on `dcyclops`. `cyclops` has none yet, so
nothing outside it can reach Grafana there. As with Pi-hole, the host forwards TCP port 443
from private addresses to the container and drops everything else sent to the address.

The interface is at `https://172.16.0.4/`. Its certificate is self-signed, so browsers warn
about it, and it's made again when the address changes. Sign in as `admin`. The password and
the key that signs sessions are generated when Grafana first starts, and stay out of the Nix
store. Read the password on the host:

```bash
sudo cat /var/lib/nixos-containers/grafana/var/lib/grafana/admin-password
```

Loki is already the default data source, next to Prometheus. The Host logs dashboard shows
failed SSH logins, `sudo` use, the rate of audit events, and errors by unit. The Containers
dashboard shows each container's state, restarts, CPU, memory, tasks, log volume, errors and
logs, for the hosts and containers picked at the top. Both come from this repo, so changes
made in the interface don't last. To read logs, use Explore with a query such as:

```logql
{host="tcyclops", identifier="sudo"}
```

Loki keeps logs for 30 days. Nothing limits its size, only age, so check the disk if a
service gets noisy. It's in `/var/lib/nixos-containers/grafana/var/lib/loki`. Prometheus
also keeps 30 days, in `/var/lib/nixos-containers/grafana/var/lib/prometheus2`.

Local logs are limited separately, so they can't fill the disk while Loki is down, or
shrink what it has already stored:

| Log | Limit |
| --- | --- |
| Host journal | 2 GB, 1 month |
| Each container's journal | 256 MB, 1 month |
| `/var/log/audit` | 10 files of 50 MB, rotated by `auditd`, which drops the oldest |
| `wtmp`, `btmp` | Monthly with one old copy, rotated by `logrotate` |
| Pi-hole's `/var/log/pihole` | `logrotate`, by date from nixpkgs, and sooner at 100 MB for `pihole.log` or 50 MB for `FTL.log` and `webserver.log` |

`logrotate` runs hourly on each host and in each container, and `modules/nixos/log-retention.nix`
turns it on and sets the journal limits. Grafana and Loki only log to their container's journal.

Loki and Prometheus have no login, so a firewall rule on the host drops connections to their
ports 3100 and 9090 from every user except `root` and `alloy` (UID 399). `alloy` can also
pass through `/var/lib/nixos-containers`, by group, but not list it, to reach the journals.
Alloy keeps its place in each journal in `/var/lib/alloy`, so after a restart it carries on from there, and if Loki is down it keeps
retrying. Lines it's still holding in memory when it stops can be lost, such as when a host
shuts down after the container. With no saved place, it starts 72 hours back.

The logs are not copied off the host, so root on a host can erase that host's logs, and
anything that wipes the host takes them too. Check it from the host:

```bash
sudo journalctl -u alloy
sudo nixos-container run grafana -- journalctl -u loki -u grafana
```

## Setting up the VMs

Do this once per VM. The ISO installs the SSH key from
`modules/nixos/common.nix`, which is the only way in over SSH. It also sets the user passwords below, for logging
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
   an existing VM has any of them elsewhere. The folder is the VM's name without the
   brackets, such as `nix tcyclops.homelab.zezura.cc`, because PowerShell reads
   brackets as wildcards.
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
   ssh -t -i ~/.ssh/nix-homelab-control-node.key -o UserKnownHostsFile=~/.ssh/known_hosts.d/172.16.0.2 captain@172.16.0.2 'passwd && sudo passwd riley'
   ```

   Use `172.16.1.2` for `dcyclops`. New passwords survive deploys, but rebuilding
   `dcyclops` resets them, so change them again after each rebuild.

Deploy later changes with `just deploy <vm>`. The ISO contains the system as it
was when built, and a deploy updates it from there.

A deploy can't change a VM's disk layout. A VM installed before a layout change in
`modules/nixos/hyperv-lvm.nix` must be reinstalled from a new ISO before its next deploy,
or it won't find its disks on reboot. Reinstalling wipes the disk.

To throw away `dcyclops` and start again, which is refused for `tcyclops`:

```bash
just vm-rebuild dcyclops
```

## Testing changes

`just test` runs what the changes since `main` can affect, without KVM or a deployed host.
Set `TEST_BASE` to compare with another branch.

| Step                                       | Without KVM         | Runs when                  |
| ------------------------------------------ | ------------------- | -------------------------- |
| Build `cyclops`, `dcyclops`, `tcyclops`    | Only what changed   | A Nix file changed         |
| `container-isolation`, `logging`, `pihole` | Under a minute each | A Nix file changed         |
| `boot`, in QEMU                            | About a minute      | Its inputs changed, below  |

Nix caches results, so a step the change can't affect takes no time. `boot` runs when
`tests/boot.nix` or `dcyclops`'s kernel, initrd, stage 2, kernel modules or parameters,
sysctls or file systems change.

Name tests to run only those, whether anything changed or not:

```bash
just test boot logging
```

`boot` only boots `dcyclops`, and QEMU skips its bootloader, so a change to only another
host's boot, or to GRUB, isn't covered. The nspawn tests can't check a container's
`privateUsers`, which they turn off to nest containers, so that's left to building the
hosts. Pi-hole's lookups and blocklist need an upstream, which the sandbox doesn't have.

The nspawn tests need these settings on the machine that builds, in its `nix.conf`:

```ini
experimental-features = nix-command flakes auto-allocate-uids
auto-allocate-uids = true
system-features = nixos-test benchmark big-parallel kvm uid-range
```

## Testing from a desktop

`vm-dev` is a temporary XFCE desktop with Firefox and a terminal, for testing services on
`dcyclops` from another machine on its network:

```bash
just vm-dev create
```

Open `[nix] vm-dev` in Hyper-V Manager. It installs itself, reboots, and logs in as `root`,
which has no password. It's at `172.16.1.254`, and uses Pi-hole on `172.16.1.3` for DNS, so
name lookups fail unless `dcyclops` is running. It has no SSH and isn't managed by
`just deploy`.

Add a tool for the current shell with `nix shell nixpkgs#<package>`. Packages download
through Pi-hole's DNS, and go when the VM does.

To stress test DNS with the sample queries, which are in root's home directory:

```bash
nix shell nixpkgs#dnsperf -c dnsperf -d ~/tests/dns/queries.txt -s 172.16.1.3 -l 30 -c 10
```

To turn it off and delete it, with its folder under `E:\Hyper-V VMs` and its ISO:

```bash
just vm-dev destroy
```

## Setting up the server

1. Install NixOS on `cyclops` with a UEFI boot setup.

2. Let WSL deploy to it. Add this to `/etc/nixos/configuration.nix` on the server,
   then run `sudo nixos-rebuild switch` there:

   ```nix
   services.openssh = {
     enable = true;
     settings = {
       PasswordAuthentication = false;
       KbdInteractiveAuthentication = false;
       PermitRootLogin = "no";
     };
   };
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
   just hardware-config cyclops <address>
   ```

4. Set `system.stateVersion` in `hosts/cyclops/configuration.nix` to the release
   you installed, and `git add` the changes.

5. Deploy. This creates `riley` with the password `PleaseChangeMe1` and locks `root`.
   It leaves the password of the existing `captain` user alone:

   ```bash
   just deploy cyclops <address>
   ```

6. Change the passwords:

   ```bash
   ssh -t -i ~/.ssh/nix-homelab-control-node.key -o UserKnownHostsFile=~/.ssh/known_hosts.d/<address> captain@<address> 'passwd && sudo passwd riley'
   ```
