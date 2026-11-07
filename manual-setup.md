# Manual setup

Everything only a person can do: passwords, keys, backups, installs and the phone. Work
down the list. The [README](README.md) explains how each part works.

Commands run from the repo root, in the dev shell.

## Back these up

| Secret                       | Path                                                       | Keep it                              |
| ---------------------------- | ---------------------------------------------------------- | ------------------------------------ |
| Admin age key                | `~/.config/sops/age/keys.txt`                              | Password manager                     |
| Control-node SSH key         | `~/.ssh/nix-homelab-control-node.key`                      | Password manager, passphrase set     |
| Main deploy signing key      | `~/.config/nix-homelab/signing.key`                        | Password manager                     |
| Backup deploy signing key    | Not on this machine                                        | Password manager only, never on disk |
| Login and service passwords  | `users/*.hash` (public), `secrets/<host>.yaml` (encrypted) | In git, and the passwords in the password manager |

## 1. Control node, once

### Dev shell

```bash
nix develop
```

It provides `just`, `sops`, `age`, `ssh-to-age`, `mkpasswd` and the formatters, and
installs the Git pre-commit hook. With [direnv](https://direnv.net), run `direnv allow`
once instead and it loads automatically.

### Control-node SSH key

`just` offers only this key, and its public half in `modules/nixos/common.nix` is the only
way in over SSH. It is also baked into the install ISO.

```bash
ssh-keygen -t ed25519 -f ~/.ssh/nix-homelab-control-node.key -C nix-homelab-control-node
```

Give it a passphrase. To add one to an existing key:

```bash
ssh-keygen -p -f ~/.ssh/nix-homelab-control-node.key
```

Back the private key up.

### Admin age key

Edits secrets. Its public half is the first recipient in `.sops.yaml`
(`age1h2xv8av7hpl4y0kyuq2yup24unl29ch8dvzpa4mamwe4vpe22pjsa8e6u3`). Restore the file from
your backup on a new machine:

```bash
mkdir -p ~/.config/sops/age
```

Copy the backup to `~/.config/sops/age/keys.txt`. Back it up whenever it changes. See
[Admin age key lost](#admin-age-key-lost) if there is no backup.

### Deploy signing key

Hosts accept a closure only if a trusted key signed it. `just signing-key` creates the main
key `nix-homelab-1` if it is missing, never overwrites it, and writes its public half:

```bash
just signing-key
```

The private half is `~/.config/nix-homelab/signing.key`, the public half is
`keys/nix-homelab-signing.pub`. Commit the public file. Back the private key up off this
machine, because anyone holding it can have a host accept any closure.

The backup key `nix-homelab-2` is trusted too, and its public half is
`keys/nix-homelab-signing-backup.pub`. Keep its private half offline only, in the password
manager, never on the control node. To replace it with `nix-homelab-3`:

```bash
nix key generate-secret --key-name nix-homelab-3
```

Store that offline, swap `keys/nix-homelab-signing-backup.pub` for its public half
(`nix key convert-secret-to-public`), commit and deploy.

### nix.conf for the tests

The nspawn tests of `just test` need these settings on the machine that builds, in its
`nix.conf`:

```ini
experimental-features = nix-command flakes auto-allocate-uids
auto-allocate-uids = true
system-features = nixos-test benchmark big-parallel kvm uid-range
```

## 2. Repo, once

### Login passwords

The hosts fail to evaluate until `users/captain.hash` and `users/riley.hash` exist. The
directory is created by the first run. Each run asks twice for a password of 15 or more
characters with upper case, lower case, a digit and a symbol, and writes a yescrypt hash:

```bash
just set-password captain
```

```bash
just set-password riley
```

The hashes are public because the repo is, so anyone can guess the password offline. Use a
long random password from a password manager, and keep it there. Flakes only see tracked
files:

```bash
git add users/captain.hash users/riley.hash
```

Commit them. Run `just set-password <user>` again to change one, then deploy.

## 3. Per host

### Service secrets

If `secrets/<host>.yaml` is missing, create it with random Pi-hole, Grafana and ntfy
passwords, encrypted for the admin key only. It never replaces a file. `secrets/cyclops.yaml`,
`secrets/tcyclops.yaml` and `secrets/dcyclops.yaml` already exist.

```bash
just secrets-init <host>
```

### Install a VM

Do this once per VM. The ISO installs the SSH key from `modules/nixos/common.nix`, and
sets the console passwords from `users/<name>.hash`, so do [Login passwords](#login-passwords)
first.

1. Build the ISO, then create and start the VM. Approve the UAC prompt, because the scripts
   in `scripts/hyper-v/` need administrator rights:

   ```bash
   just vm-create tcyclops
   ```

   The ISO **wipes the disk with no prompt**. It only checks that it runs under Hyper-V, so
   attach it only to its own VM, never to a Debian one. The ISO goes in your Windows
   Downloads folder. To put it elsewhere on a Windows drive:
   `just iso_dir=/mnt/e/isos vm-create tcyclops`. Pass `-Force` or `-Reinstall` after the VM
   name for those script options.

2. Enable forwarding on the new switches:

   ```bash
   just vm-forwarding
   ```

3. [Rekey and deploy](#rekey-and-deploy).

To throw away `dcyclops` and start again, which is refused for `tcyclops`:

```bash
just vm-rebuild dcyclops
```

A VM installed before a layout change in `modules/nixos/hyperv-lvm.nix` must be reinstalled
from a new ISO before its next deploy.

### Install the server

1. Install NixOS on `cyclops` with a UEFI boot setup.

2. Let WSL deploy to it. Add this to `/etc/nixos/configuration.nix` on the server, then
   run `sudo nixos-rebuild switch` there:

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
     hashedPassword = "<the contents of users/captain.hash>";
     openssh.authorizedKeys.keys = [ "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJGshhca+nI1Qt1zDNvHCYIokESlCHMi+0JjvcdW7+3F nix-homelab-control-node" ];
   };
   ```

3. From WSL, replace the placeholder hardware config. `just deploy` refuses to run until
   you do:

   ```bash
   just hardware-config cyclops <address>
   ```

4. Set `system.stateVersion` in `hosts/cyclops/configuration.nix` to the release you
   installed, and `git add` the changes.

5. If `secrets/cyclops.yaml` is missing, run `just secrets-init cyclops`. Then
   [rekey and deploy](#rekey-and-deploy). The deploy creates `riley`, locks `root`, and
   sets both logins from `users/`.

### Rekey and deploy

A new install has a new SSH host key, so it can't decrypt `secrets/<host>.yaml` yet, and
its Pi-hole, Grafana and ntfy containers keep restarting until you rekey. `just deploy`
refuses until it is done. Do this after every install, including `just vm-rebuild`:

```bash
just secrets-rekey tcyclops
```

It fetches the host's public key over SSH and shows its fingerprint. Compare it with
`ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` on the host's console, because a first
connection can't prove whose key it is. For `cyclops`, give the address:
`just secrets-rekey cyclops <address>`. Then deploy:

```bash
just deploy tcyclops
```

Commit the changed `.sops.yaml` and `secrets/<host>.yaml`. Deploy later changes to a VM
first, then to the server.

### Move an existing host here

In this order:

1. Run `just set-password` for `captain` and `riley`, and commit. Evaluation fails without
   them.
2. Optionally, keep Grafana's database readable: put the old key from
   `/var/lib/nixos-containers/grafana/var/lib/grafana/secret-key` in `grafana-secret-key`
   with `sops secrets/<host>.yaml`. A different key makes anything Grafana encrypted in its
   database unreadable, which is only stored data-source and alert secrets. The ntfy
   password is one, and is stored again at each start, so nothing is lost.
3. `just secrets-rekey <host>`, then commit.
4. `just deploy <host>`. The sudo prompt wants `captain`'s old password, because nothing is
   activated yet. Pi-hole and Grafana restart, so DNS and the dashboards drop briefly.
5. Afterwards, the Pi-hole and Grafana passwords are the sops ones, and `captain`'s sudo
   password is the one from `users/captain.hash`.
6. Delete what the old design left in the containers' state, which is now unused:
   `pihole/var/lib/pihole/web-password.env` and
   `grafana/var/lib/grafana/{admin-password,secret-key}` under
   `/var/lib/nixos-containers/`.

## 4. Per phone

Set up [ntfy](README.md#alerts-ntfy) alerts on Android, once per host:

1. Install the ntfy app.
2. Get the certificate and send it to the phone. It's public, but only root can read it on
   the host, so this asks for `captain`'s sudo password:

   ```bash
   just ntfy-cert dcyclops > ntfy.pem
   ```

3. In the app, open Settings, Advanced, Manage certificates and import `ntfy.pem` (needs
   app 1.22.2 or newer). Compare the SHA-256 fingerprint it shows with the one printed on
   the host's console by:

   ```bash
   sudo openssl x509 -noout -fingerprint -sha256 -in /var/lib/nixos-containers/ntfy/var/lib/private/ntfy-sh/tls.crt
   ```

   The certificate is made again when the address changes or it nears expiry, so import it
   again then.
4. Print the password:

   ```bash
   sops -d --extract '["ntfy-phone-password"]' secrets/dcyclops.yaml
   ```

5. Subscribe to topic `alerts` on the host's own ntfy address (see
   [Service addresses](README.md#service-addresses)), such as `https://172.16.1.5` for
   `dcyclops`, with user `phone` and that password.

The VMs' addresses are behind the Hyper-V NAT switch, so a phone on the home Wi-Fi can't
reach them as they are. Add a route on the Windows PC and tell the router, or map the port
on Windows with `netsh interface portproxy` to the address and give the phone the PC's
address instead, which also changes what the certificate must say. A physical `cyclops` on
the LAN needs neither. The iOS app only gets alerts when it polls, which is delayed.

## 5. Recurring

| When                              | Do                                                                |
| --------------------------------- | ----------------------------------------------------------------- |
| After a WSL restart               | `just vm-forwarding`, because Windows resets forwarding on the WSL adapter |
| After a deploy                    | [Reset the AIDE baseline](#aide-baseline)                         |
| Changing a login password         | `just set-password <user>`, commit, deploy                        |
| Changing a service password       | [Edit the secrets](#service-passwords), deploy                    |
| After reinstalling a host         | [Rekey and deploy](#rekey-and-deploy)                             |
| After a compromise                | [Rotate the secrets](#after-a-compromise)                         |

### AIDE baseline

The weekly AIDE check of `/boot` and `/etc` fails after any deploy. To accept the new
baseline, delete the database on the host, and the next run recreates it:

```bash
sudo rm /var/lib/aide/aide.db
```

### Service passwords

The keys are `pihole-web-password`, `grafana-admin-password`, `grafana-secret-key`,
`ntfy-grafana-password` and `ntfy-phone-password`. Edit or read them with sops, then
deploy. The affected containers restart on their own, and the new values replace the old
ones:

```bash
sops secrets/dcyclops.yaml
```

```bash
sops -d --extract '["grafana-admin-password"]' secrets/dcyclops.yaml
```

Never keep a decrypted file in the repo. `.gitignore` blocks the usual names (`*.dec`,
`*.decrypted`, `keys.txt`). Update the phone's password in the ntfy app after changing
`ntfy-phone-password`.

### After a compromise

Rekeying doesn't change the values, and the old ciphertext stays in git history. After
reinstalling a compromised host, or if a key leaked, rekey, then change the values with
`sops secrets/<host>.yaml` and deploy. If the backup signing key was used on an untrusted
machine or leaked, replace it as in [Deploy signing key](#deploy-signing-key).

## 6. Recovery

### Main signing key leaked or lost

The backup key lets you deploy and replace it:

1. Move the old main key aside, run `just signing-key`, and commit the new
   `keys/nix-homelab-signing.pub`. The old public key is now gone from the config.
2. Restore the backup key's private half to a temporary file and deploy to every host
   signed by it. The hosts still trust the backup key, and the deploy delivers the new main
   key. Delete the temporary file afterwards:

   ```bash
   NIX_HOMELAB_SIGNING_KEY=/path/to/backup.key just deploy <host>
   ```

3. If the backup key was used on an untrusted machine, or leaked itself, make
   `nix-homelab-3` as in [Deploy signing key](#deploy-signing-key), and deploy again.

### Both signing keys lost

Deploys fail with "lacks a signature by a trusted key", because the hosts trust only the old
public key. A normal deploy can't deliver the new key, so:

1. Move the old key aside, run `just signing-key`, and commit the new public file.
2. Build the host and copy its closure over as a file, then import it on the host as root,
   which needs no signature:

   ```bash
   out=$(nix build --no-link --print-out-paths .#nixosConfigurations.<host>.config.system.build.toplevel)
   nix-store --export $(nix-store --query --requisites "$out") > closure.nar
   scp -i ~/.ssh/nix-homelab-control-node.key closure.nar captain@<address>:
   # on the host:
   sudo nix-store --import < closure.nar
   sudo nix-env -p /nix/var/nix/profiles/system --set <out>
   sudo <out>/bin/switch-to-configuration switch
   ```

   Later deploys work, since the host now trusts the new key. The `nix-signing` test
   covers a root import of an unsigned path; the copy and activation steps are untested.

### Admin age key lost

Nobody can edit the secrets. The only fix is a new key, new secrets files and new passwords
everywhere:

1. Make a new key, and back it up:

   ```bash
   age-keygen -o ~/.config/sops/age/keys.txt
   ```

2. Replace the admin recipient (the first one) in `.sops.yaml` with its public key.
3. Move the old `secrets/<host>.yaml` files aside and run `just secrets-init <host>` for
   each host.
4. [Rekey](#rekey-and-deploy) each host, then deploy. Set the phone's ntfy password again.
