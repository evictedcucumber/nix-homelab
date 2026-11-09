# nix-homelab

NixOS homelab managed with a Nix flake, and deployed over SSH from the control node.

## Machines

| Machine         | What it is                      | Where it runs                  | Role                                          |
| --------------- | ------------------------------- | ------------------------------ | --------------------------------------------- |
| Control node    | NixOS-WSL, or a NixOS machine   | Windows PC, or a separate PC   | Runs `just`, builds, signs and deploys, and holds the keys |
| Windows PC      | Windows with Hyper-V            | On its own                     | Hosts the three VMs below                     |
| `tcyclops`      | Hyper-V VM                      | Windows PC                     | Long-lived test VM                            |
| `dcyclops`      | Hyper-V VM                      | Windows PC                     | Throwaway dev VM, rebuilt whenever needed     |
| `dev`           | Hyper-V VM                      | Windows PC                     | Temporary desktop for testing `dcyclops`      |

A physical production host, `cyclops`, is planned and will be added later.

The control node's own configuration isn't in this repo. The Hyper-V recipes and reaching the VMs need NixOS-WSL
on that PC, because the VMs sit on internal Hyper-V switches behind its NAT. A standalone
NixOS control node can't manage any host yet. Each manual step says where it runs, in
[`manual-setup.md`](manual-setup.md).

These VMs mirror the Debian `tcyclops` and `dcyclops` from the `homelab` repo and
run alongside them. Both labs use the same FQDNs, and only the Hyper-V VM names differ:

| Debian VM name               | Nix VM name                        |
| ---------------------------- | ---------------------------------- |
| `tcyclops.homelab.zezura.cc` | `[nix] tcyclops.homelab.zezura.cc` |
| `dcyclops.homelab.zezura.cc` | `[nix] dcyclops.homelab.zezura.cc` |

## Layout

| Path              | Purpose                                                                  |
| ----------------- | ------------------------------------------------------------------------ |
| `flake.nix`       | Hosts, install ISOs, dev shell, formatter and checks                     |
| `hosts/<name>/`   | Per-host configuration                                                   |
| `modules/nixos/`  | Config shared between hosts, and the unattended installer                |
| `modules/containers/` | The container framework, the in-container modules, and each container |
| `templates/`      | `container`, a skeleton for a new container                              |
| `home/`           | Home Manager config for each user                                        |
| `scripts/`        | `deploy.sh`, `secrets.sh`, `check-secrets.sh`, the test runner, and Hyper-V network and VM setup |
| `secrets/`        | Per-host sops files holding the service passwords                        |
| `users/`          | Login password hashes, one `<user>.hash` each, created by `just set-password` |
| `keys/`           | Public halves of the deploy signing keys                                 |
| `tests/`          | NixOS tests, run by `just test`                                          |
| `treefmt.nix`     | Formatters and linters run by `nix fmt`                                  |
| `justfile`        | Common commands                                                          |
| `manual-setup.md` | Checklist of the setup steps only a person can do                        |

On a new machine, start with [`manual-setup.md`](manual-setup.md): passwords, keys,
backups, installs and the phone. The hosts fail to evaluate until `users/captain.hash` and
`users/riley.hash` exist.

## Development

Enter the dev shell, which provides `just`, `lefthook`, `nixos-rebuild`, the `nixd`
language server, `sops`, `age`, `ssh-to-age`, `mkpasswd` and the formatters, and installs
the Git pre-commit hook:

```bash
nix develop
```

With [direnv](https://direnv.net), run `direnv allow` once and it loads
automatically.

The pre-commit hook checks the staged files with the same formatters and linters
as `just fmt`. It rejects the commit if anything fails. If a formatter rewrites a
file, `git add` it and commit again.

Run `just` to list the recipes:

| Recipe                                 | What it does                                 |
| -------------------------------------- | -------------------------------------------- |
| `just fmt`                             | Format and lint with nixfmt, deadnix, statix |
| `just pre-commit`                      | Run the pre-commit checks on every file      |
| `just check`                           | Evaluate every host and check formatting     |
| `just test [names]`                    | Run the tests a change can affect            |
| `just update [input]`                  | Update flake inputs                          |
| `just build <host>`                    | Build a host's system without activating it  |
| `just set-password <user>`             | Write a login password's hash to `users/`    |
| `just secrets-init <host>`             | Create a host's secrets file, never replacing |
| `just secrets-rekey <host>`            | Encrypt a host's secrets for its SSH host key |
| `just ntfy-cert <host>`                | Print a host's ntfy certificate, to import into the phone |
| `just signing-key`                     | Create the deploy signing key if missing     |
| `just vulnix <host>`                   | Scan a host's closure for known CVEs         |
| `just deploy <host>`                   | Build and activate, offering a needed reboot |
| `just deploy-test <host>`              | Same, but revert on the host's next reboot   |
| `just reboot <host>`                   | Reboot the host, after a `sudo` prompt       |
| `just iso <vm> [dir]`                  | Build a VM's unattended-install ISO † |
| `just vm create <vm> [flags]`          | Build a VM's ISO, then create and start it † |
| `just vm rebuild <vm>`                 | Recreate `dcyclops` or `dev` from a new ISO † |
| `just vm destroy <vm>`                 | Remove `dcyclops` or `dev` with its disks and ISO † |
| `just vm compact <vm>`                 | Trim a VM, then shrink its VHDX files † |
| `just vm forwarding [flags]`           | Enable Windows forwarding to the VM networks † |
| `just hardware-config <host>`          | Fetch a host's generated hardware config     |
| `just clean`                           | Remove `result` links                        |

† Needs a NixOS-WSL control node on the Hyper-V PC (`just iso` only when `dir` is left
out). So does any recipe that connects to `tcyclops` or `dcyclops`. Everything else works
from either kind of control node.

Recipes that connect to a host log in as `captain` at the address `scripts/deploy.sh` knows
for it, so add a new host there first. Flakes only see files tracked by git,
so `git add` new files before building.

SSH connections from `just` offer only the private key
`~/.ssh/nix-homelab-control-node.key`, which matches the public key in
`modules/nixos/common.nix`.

Deploy changes to a VM first:

```bash
just deploy tcyclops
```

A deploy checks SSH first, then builds on the control node, signs the closure with the deploy key, and
copies it as `captain`. It prints what changed from the running system, then activates with
`nixos-rebuild --store-path`, which asks for `captain`'s sudo password once and uses it for
both the profile update and the activation. The hosts set `max-jobs = 0`, so any build
started on one fails, including `nixos-rebuild` or `nix-shell` run there.

### Signing key

Only root is a trusted Nix user on the hosts, so `captain` can add a store path only if it
is signed by a key in `trusted-public-keys`. The key is `nix-homelab-1`: its private half
is `~/.config/nix-homelab/signing.key` and its public half is committed as
`keys/nix-homelab-signing.pub`. A second, backup key `nix-homelab-2` is trusted as well,
with its public half in `keys/nix-homelab-signing-backup.pub`. Its private half is kept
offline only (password manager), never on the control node.

`just signing-key` creates the private key if it is missing, and never overwrites it. It
then rewrites the public file from it. Anyone holding the private key can have a host
accept any closure. For creating and backing up the keys, and recovering when one is lost
or leaked, see [`manual-setup.md`](manual-setup.md#deploy-signing-key).

### Vulnerability scan

`just vulnix <host>` builds the host's system closure here and scans it with
[vulnix](https://github.com/nix-community/vulnix), which downloads the NVD feed, so it
runs on the control node and never on a host. vulnix exits 2 when it reports
vulnerabilities, and the recipe then prints a note instead of looking like a crash.

To accept a finding, add it to `vulnix-whitelist.toml`, with a reason:

```toml
["openssl-3.0.0"]
cve = ["CVE-2024-0000"]
comment = "not reachable from the network"
```

`vulnix --write-whitelist FILE` can generate entries from the current findings.

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

Both VMs sit behind `NixHomelabNAT` on `172.16.0.0/16`, which
`just vm create` creates if it's missing. The Debian lab stays on `10.0.1.0/24` and
`10.0.2.0/24` behind its own `HomelabNAT` on `10.0.0.0/16`, and the scripts here never
change or remove any NAT. Each host holds the `.1` address of its VM's subnet as the
gateway, and the VMs use static addresses because internal switches have no DHCP.

Microsoft [supports only one NAT per host](https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/setup-nat-network),
and warns that creating more leaves the system in an unknown state. Running both labs
is therefore unsupported, and `just vm create` warns when it finds another NAT. If VM
networking misbehaves with both in place, check `Get-NetNat` first. `just vm create`
also stops if another adapter has an address in `172.16.0.0/16`, because Windows picks
the WSL and Default Switch subnets from the same private range.

Nothing here changes NixOS-WSL itself. Its default route already goes through Windows,
so it needs no routes of its own. `just` uses addresses directly, so it needs no
SSH config. It keeps host keys in `~/.ssh/known_hosts.d/`, one file per address, and
never touches `~/.ssh/known_hosts`. Builds only add to the control node's Nix store, and
every deploy activates on its target.

`just` trusts a host's key the first time it connects, and refuses it if it later
changes. Reinstalling a VM changes its key, so `just vm create` and `just vm rebuild`
remove the old one.

After a NixOS-WSL restart, run `just vm forwarding` again, because Windows resets forwarding on
the WSL adapter.

### Service addresses

Pi-hole, Grafana and ntfy each have an address of their own on the host's network:

| Service              | Host number | `tcyclops`   | `dcyclops`   |
| -------------------- | ----------- | ------------ | ------------ |
| [Pi-hole](#pi-hole)  | 3           | `172.16.0.3` | `172.16.1.3` |
| [Grafana](#logging)  | 4           | `172.16.0.4` | `172.16.1.4` |
| [ntfy](#alerts-ntfy) | 5           | `172.16.0.5` | `172.16.1.5` |

A host sets only its network, as `lan.prefix = "172.16.0";`, and gets its own address (`.2`),
the gateway (`.1`) and each container's address from it. A container's module sets the last
octet once, as `containers.<name>.lan.hostNumber`. Without a `lan.prefix`, the container has
no address. `containers.<name>.lan.address` still overrides the derived address, but the host
then has to put it on an interface itself.

It is a second address on the host, not a separate interface, because containers only get
their [`ve-<name>` interface](#containers). The host forwards the service's ports from
private addresses to its container and drops everything else sent to the address, so SSH
stays on the host's own address, and the service doesn't answer on that one. With no
address, nothing outside the host can reach the service.

## Users

| User      | UID and GID | Sudo               | Login                               |
| --------- | ----------- | ------------------ | ----------------------------------- |
| `captain` | 1000        | Yes, with password | SSH key, or password at the console |
| `riley`   | 2000        | No                 | Password at the console only        |

`root` still exists, because NixOS needs it, but its password is locked (`!`) and its SSH
login is off. Passwords come from [`users/<name>.hash`](#secrets-and-passwords), and
`users.mutableUsers = false` makes every activation reset them, so `passwd` changes don't
last. Use `sudo` from `captain` instead. Emergency mode needs the
root password, so it won't open. To recover from a bad deploy, boot an earlier
generation from the boot menu.

SSH only accepts public keys, and only for `captain`. Keys must be set in
`modules/nixos/common.nix`, because `sshd` ignores `~/.ssh/authorized_keys`. Forwarding
and tunnels are off, so `ssh -L`, `-R`, `-D` and `-A` won't work. To give `riley` SSH
access, add a key for that user and add `riley` to `AllowUsers`. Idle sessions close after
10 minutes, and more than 30 new SSH connections a minute from one address are dropped.

Home Manager manages each user's environment, and deploys with the system. Put settings
for everyone in `home/common.nix`, and for one user in `home/<user>.nix`. Packages in
`home.packages` go to that user only, so use them rather than the system list where you
can. Set `home.stateVersion` once and leave it. A file Home Manager needs to replace is
renamed with `.hm-bak`. If a deploy fails on `home-manager-<user>.service`, check
`journalctl -u home-manager-<user>`. A new user also needs adding to the list in
`modules/nixos/home-manager.nix`.

`modules/nixos/firewall.nix` drops everything in, out and forwarded except inbound SSH
and outbound NTP, NTS and DNS over TLS, plus their replies. Hosts can't start any other
outbound connection, so everything reaches them by `just deploy` from the control node. IPv6 is off,
and hosts don't answer ping. A host can also connect to its own [containers](#containers),
and forwards inbound DNS and web traffic for one extra address to [Pi-hole](#pi-hole), and
web traffic for others to [Grafana](#logging) and [ntfy](#alerts-ntfy).

DNS goes from `systemd-resolved` to `dnsdist`, which sends it over TLS to Cloudflare, or
to Quad9 while Cloudflare is down, and returns to Cloudflare when it recovers. There's no
plain DNS fallback, and the firewall blocks outbound port 53. `chrony` uses
`time.cloudflare.com` over NTS.

## Containers

`modules/containers/framework/` sets up
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

The host's modules don't apply inside a container, so the SSH settings stop
at the host. Open a shell in one from the host:

```bash
sudo nixos-container root-login web
```

The framework also adds options to each container, besides the NixOS ones:

| Option                                | Effect                                                              |
| ------------------------------------- | ------------------------------------------------------------------- |
| `containers.<name>.lan`               | `address`, `ports` and `fromHost`: forwards ports from the host's network, in a `<name>-dnat` nftables table |
| `containers.<name>.credentials`       | Sops secret ids, loaded into the container under the same names     |
| `containers.<name>.restartAlways`     | Restarts the container when it stops, true by default               |

Every container also imports `modules/containers/guest/base.nix`, which sets up its firewall,
log retention and minimal profile. A container opts in to
`guest/monitoring.nix` to have Alloy ship its journal, and to `guest/tls.nix` for a self-signed
certificate.

### Adding a container

1. Copy `templates/container/` to `modules/containers/<name>/` and replace `example`.
2. Pick an unused address in `10.233.0.0/24`, and set it as `localAddress`.
3. Add the directory to the imports in `modules/containers/default.nix`.
4. To reach it from the host's network, list its `lan.ports` and set
   `lan.hostNumber`, an unused last octet other than the host's (`2`) and the gateway's
   (`1`). A host with a `lan.prefix` then gets the address.
5. Import `../guest/monitoring.nix` in its `config` to have its logs shipped.

Each container has its own firewall, inside the container, which drops everything in and
out, including DNS. Outbound traffic has to pass both that firewall and the host's, so
allowing something on one side changes nothing until the other allows it too:

| To allow             | In the container's `config`                                  | On the host                                                        |
| -------------------- | ------------------------------------------------------------ | ------------------------------------------------------------------ |
| DNS                  | `containerFirewall.allowDns = true;`                         | Nothing, this opens it there too                                   |
| Outbound connections | `containerFirewall.extraOutputRules = "tcp dport 443 accept";` | `networking.firewall.extraForwardRules = ''iifname "ve-web" tcp dport 443 accept'';` |
| Inbound from the host | `networking.firewall.allowedTCPPorts = [ 80 ];`              | Nothing, the host can connect to its containers                    |
| Inbound from another container | `containerFirewall.allowFrom.web = [ 8080 ];`, in the destination, naming the source | Nothing, this opens the port there too and forwards only it, from only `web` |

Root in a container can flush that container's firewall, so treat it as policy for what
the container should do, and the host's rules as the limit on a compromised one. The host
always blocks the rest:

- A container's root isn't root on the host, and the host's Nix daemon refuses it.
- A container can't reach other containers, except the TCP ports the destination lists in
  `containerFirewall.allowFrom` for that source, or forge its source address. It can't
  reach them through their `forwardPorts` either.
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

`modules/containers/pihole/` runs Pi-hole on every host, in a container named `pihole` at
`10.233.0.2`. Clients reach it on its own address (see
[Service addresses](#service-addresses)).

| Service | Port |
| --- | --- |
| DNS | 53, UDP and TCP |
| Web interface | 443, with port 80 redirecting to it |

```bash
dig @172.16.0.3 pi.hole
```

The web interface is at `https://172.16.0.3/`, or `https://pi.hole/` for clients using
Pi-hole for DNS. Its certificate is self-signed, so browsers warn about it. The password
is `pihole-web-password` in `secrets/<host>.yaml`, so every start sets it again. Read it
with `sops -d --extract '["pihole-web-password"]' secrets/<host>.yaml`, and see
[Secrets and passwords](#secrets-and-passwords) to change it. Settings are read-only in
the interface, because they come from this repo.

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

`modules/containers/grafana/` runs Grafana, Loki and Prometheus on every host, in one container
named `grafana` at `10.233.0.3`, because containers can't reach each other. Alloy runs on the
host and sends its journal to Loki. The journal holds SSH and `sudo` logs
and every service's output, and each line is labelled with the host, `unit`, `identifier`,
`transport` and `level`.

Every container in `containers` is picked up with no setup: Alloy also reads each one's journal
from `/var/lib/nixos-containers/<name>/var/log/journal`, labelled with the host and
`container`. The label comes from the config, not from the journal, which the container
controls. Alloy also sends the state, restarts and tasks of every service on the host, which includes
each container's (from `systemd`), and each container's CPU and memory (from cAdvisor) to
Prometheus. Alloy restarts when a container starts with a
journal newer than Alloy, such as on its first start, so it finds the new journal.

Grafana is on its own address (see [Service addresses](#service-addresses)), and the host
forwards TCP port 443 to it.

The interface is at `https://172.16.0.4/`. Its certificate is self-signed, so browsers warn
about it, and it's made again when the address changes. Sign in as `admin`. The password is
`grafana-admin-password` in `secrets/<host>.yaml`, and the key that signs sessions and
encrypts Grafana's database is `grafana-secret-key`. Every start sets the admin password
again, even on an existing database, so a change made in the interface doesn't last. Read
it with `sops -d --extract '["grafana-admin-password"]' secrets/<host>.yaml`.

Loki is already the default data source, next to Prometheus. The Host logs dashboard shows
failed SSH logins, `sudo` use, and errors by unit. The Containers
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

## Alerts (ntfy)

Grafana raises alerts and [ntfy](https://ntfy.sh) delivers them to a phone. Both run on every
host, each in its own container, and each host alerts about itself. `modules/containers/ntfy/`
runs ntfy in a container named `ntfy` at `10.233.0.4`, and `modules/containers/grafana/` provisions Grafana's
contact point, notification policy, message template and rules, so nothing is set up in the
interface. Grafana can still be used without ntfy: the alerts just have nowhere to go.

Grafana posts to `http://10.233.0.4:8080/alerts?template=grafana`. That port is the only one
Grafana's container can reach in another container, set with `containerFirewall.allowFrom`, and
no other container reaches ntfy. The messages hold only the alert name, host, severity and a
short summary, such as `warning on dcyclops: /var is over 85% full`, never log lines or links.

| Alert | Metric | Fires when |
| --- | --- | --- |
| Filesystem almost full | `node_filesystem_avail_bytes`, `node_filesystem_size_bytes` | A filesystem has been over 85% full for 10 minutes |
| Low memory | `node_memory_MemAvailable_bytes`, `node_memory_MemTotal_bytes` | Under 10% is available for 10 minutes |
| Service failed | `node_systemd_unit_state` | A service has been `failed` for 2 minutes |
| Service restarting | `node_systemd_service_restart_total` | A host service restarted three times in 15 minutes; `container@*` units count, services inside containers don't |
| No metrics | `node_boot_time_seconds` | The host's metrics are missing for 10 minutes, which means Alloy or Prometheus is down |

The systemd rules see the host's units, including each `container@<name>.service`, but not the
services running inside the containers. Grafana can't tell you it's down itself, and neither can
ntfy, so a dead Grafana or ntfy is silent. `severity=critical` alerts reach the phone with high
priority, the rest with the default.

ntfy is on its own address (see [Service addresses](#service-addresses)), and the host
forwards TCP port 443 to it over TLS. The certificate is self-signed, made when ntfy first
starts, and again when the address changes or 30 days before it expires.

Access is denied unless granted. Two users exist, with passwords from `secrets/<host>.yaml`: `grafana`
(`ntfy-grafana-password`) can only publish to the `alerts` topic, and `phone`
(`ntfy-phone-password`) can only read it. The web app and attachments are off. At every start ntfy
hashes the passwords from the container's credentials and gets its users that way, so neither a
password nor a hash is in the Nix store, and it refuses to start if one is empty. A changed password
applies once you deploy.

**Phone setup.** The steps for Android are in
[`manual-setup.md`](manual-setup.md#4-per-phone). ntfy has no way out, so it can't use
`ntfy.sh` to wake an iOS device, and the iOS app only gets alerts when it polls, which is
delayed. Android holds a connection to the server open instead, so it needs the phone to
reach the address. The VMs' addresses are behind the Hyper-V NAT switch (see
[Networking](#networking)), so a phone on the home Wi-Fi needs a route or port mapping to
reach them.

Check it from the host:

```bash
sudo nixos-container run ntfy -- journalctl -u ntfy-sh
sudo nixos-container run grafana -- journalctl -u grafana | grep -i alert
```

## Setting up hosts

The steps for each host are in [`manual-setup.md`](manual-setup.md#3-per-host): installing a
VM, rekeying its secrets and deploying.

The ISO installs the SSH key from `modules/nixos/common.nix`, which is the only way in over
SSH, and sets the user passwords from `users/<name>.hash` for the VM's console. Each VM is
Generation 2, with nested virtualization and every integration service on, and the guest
runs the Hyper-V daemons. The script stops if any of that isn't in place.

`tcyclops` and `dcyclops` each get a 512 GB system disk for the OS, configuration and
service data, and two 8 TB data disks mirrored (RAID 1) into one 8 TB array mounted at
`/srv/media` for images, videos, ISOs and other large files. Members of the `media` group
(`captain` and `riley`) can write there, and Grafana alerts if the array loses a disk. All
disks are dynamic VHDX files, so they only take the space the guest has written. The script
adds missing data disks to an existing VM, never resizes its system disk, and stops if the VM
has any other disk attached.

The ISO goes in your Windows Downloads folder, or in `iso_dir` if set. The VM's disks,
configuration and checkpoints all go in its folder under `E:\Hyper-V VMs`, and the script
stops if an existing VM has any of them elsewhere. The folder is the VM's name without the
brackets, such as `nix tcyclops.homelab.zezura.cc`, because PowerShell reads brackets as
wildcards.

The ISO **wipes the VM's disks with no prompt**, then reboots into the installed system. It only
checks that it's running under Hyper-V, not which VM it's in, so it would also wipe a
Debian VM. Only attach it to its own VM.

The ISO contains the system as it was when built, and a deploy updates it from there. A
deploy can't change a VM's disk layout. A VM installed before a layout change in
`modules/nixos/hyperv-lvm.nix` must be reinstalled from a new ISO before its next deploy, or
it won't find its disks on reboot. Reinstalling wipes the disk. `just vm rebuild dcyclops`
throws `dcyclops` away and reinstalls it, and is refused for `tcyclops`.

## Secrets and passwords

Nothing secret is in the Nix store as plaintext, and no password is set by hand.

| What | Where | How it reaches the host |
| --- | --- | --- |
| `captain` and `riley` login passwords | `users/<name>.hash`, yescrypt, in git | `hashedPassword` in `modules/nixos/common.nix` |
| Grafana admin password and secret key, ntfy passwords, Pi-hole web password | `secrets/<host>.yaml`, encrypted with sops | sops-nix decrypts them on the host, and a systemd credential carries each into its [container](#containers) |

**Keys.** Each host decrypts with an age key derived from its SSH host key
(`/etc/ssh/ssh_host_ed25519_key`), which never leaves it. You edit with the admin age key
in `~/.config/sops/age/keys.txt`, whose public half is the first recipient in
`.sops.yaml`. Without it, nobody can edit the secrets, so back it up. A fixed host key
committed to the repo would let anyone read the secrets, so the host keys are made on each
install instead.

**Login passwords.** `just set-password <user>` asks twice, needs 15 characters with all
four character classes, and writes the hash to `users/<name>.hash`. Run it again to change
a password, then deploy. The hashes are public, because this repo is, so anyone can try to
guess the password offline, and a long random password is the defence. They stay out of
sops so that a fresh install can log in before it has its host key rekeyed.

**Service passwords.** `just secrets-init <host>` creates `secrets/<host>.yaml` with random
values, encrypted for the admin key only, and never replaces a file. Edit or read it with
`sops`. After a deploy the affected containers restart on their own, and the new values
replace the old ones, because every start sets them again. No decrypted file belongs in
the repo, and `.gitignore` blocks the usual names (`*.dec`, `*.decrypted`, `keys.txt`).

**After a reinstall.** A new install has a new host key, which can't decrypt anything yet,
so its Pi-hole, Grafana and ntfy containers fail and restart until you rekey.
`just secrets-rekey <host>` fetches the host's public key over SSH, shows its fingerprint
and asks you to confirm it matches `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` on
the host's console, because a first connection can't prove whose key it is. It then
replaces the recipient marked `# host` in `.sops.yaml`, keeping every other recipient such
as a second admin key, and re-encrypts `secrets/<host>.yaml`. `just vm create` prints this
step, and `just deploy` checks the host's key is a recipient first and refuses, naming this
recipe, if it isn't. Both need the dev shell, for `ssh-to-age`.

Rekeying doesn't change the values, and the old ciphertext stays in git history. After
reinstalling a compromised host, or if a key leaked, also change the values with
`sops secrets/<host>.yaml`, then deploy.

The steps for all of this, and for moving an existing host here, are in
[`manual-setup.md`](manual-setup.md).

## Testing changes

`just test` runs what the changes since `main` can affect, without KVM or a deployed host.
Set `TEST_BASE` to compare with another branch.

| Step                                       | Without KVM         | Runs when                  |
| ------------------------------------------ | ------------------- | -------------------------- |
| `checks.x86_64-linux.eval`                 | Seconds             | A Nix file changed         |
| Build `dcyclops`, `tcyclops`               | Only what changed   | A Nix file changed         |
| `container-isolation`, `logging`, `pihole` | Under a minute each | A Nix file changed         |
| `nix-signing`, in QEMU                     | About a minute      | A Nix file changed         |
| `boot`, in QEMU                            | About a minute      | Its inputs changed, below  |

Nix caches results, so a step the change can't affect takes no time. `boot` runs when
`tests/boot.nix` or `dcyclops`'s kernel, initrd, stage 2, kernel modules or parameters,
sysctls or file systems change.

`eval` (in `tests/eval/`) breaks one thing at a time in `dcyclops` and checks that the
matching assertion fails, and that no real host fails any. It needs no VM or KVM, so
`nix flake check` runs it too.

Name tests to run only those, whether anything changed or not:

```bash
just test boot logging
```

`boot` only boots `dcyclops`, and QEMU skips its bootloader, so a change to only another
host's boot, or to GRUB, isn't covered. The nspawn tests can't check a container's
`privateUsers`, which they turn off to nest containers, so that's left to building the
hosts. Pi-hole's lookups and blocklist need an upstream, which the sandbox doesn't have.

The tests decrypt `tests/secrets/secrets.yaml` with the throwaway key beside it, and use
throwaway login hashes. Their values are public on purpose and protect nothing, so never
reuse them. The real `users/*.hash` files don't matter to the tests.

The nspawn tests need Nix settings on the machine that builds, which is the control node, listed in
[`manual-setup.md`](manual-setup.md#nix-settings-for-the-tests), set in the control node's NixOS configuration.

## Testing from a desktop

`dev` is a temporary XFCE desktop with Firefox and a terminal, for testing services on
`dcyclops` from another machine on its network:

```bash
just vm create dev
```

Open `[nix] dev` in Hyper-V Manager. It installs itself, reboots, and logs in as `root`,
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
just vm destroy dev
```
