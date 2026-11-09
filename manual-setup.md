# Manual setup

Everything only a person can do: passwords, keys, backups, installs and the phone. Work
down the list. The [README](README.md) explains how each part works.

Commands run from the repo root, in the dev shell, on the control node unless a step says
otherwise. Each step starts with **On:**, naming where it runs:

| Where            | What it is                                                                      |
| ---------------- | ------------------------------------------------------------------------------- |
| **Control node** | Where you run `just`, build, sign and deploy, and where the keys live. Either NixOS-WSL on the Windows PC, or a separate NixOS machine |
| **Windows**      | The Windows PC with Hyper-V: a UAC prompt, or Hyper-V Manager                    |
| **Host**         | A shell on the host: SSH in as `captain` from the control node, or its console    |
| **Host console** | A VM's console in Hyper-V Manager                                                |
| **Phone**        | The Android phone                                                               |

**(NixOS-WSL)** marks control-node steps that only work from NixOS-WSL on the Hyper-V PC.
A standalone NixOS control node can't manage any host yet. Hosts have no `nixos-rebuild`
and can't build, so never run a build on one.

## Back these up

| Secret                       | Path, on the control node                                  | Keep it                              |
| ---------------------------- | ---------------------------------------------------------- | ------------------------------------ |
| Admin age key                | `~/.config/sops/age/keys.txt`                              | Password manager                     |
| Control-node SSH key         | `~/.ssh/nix-homelab-control-node.key`                      | Password manager, passphrase set     |
| Main deploy signing key      | `~/.config/nix-homelab/signing.key`                        | Password manager                     |
| Backup deploy signing key    | Not on the control node                                    | Password manager only, never on disk |
| Login and service passwords  | `users/*.hash` (public), `secrets/<host>.yaml` (encrypted) | In git, and the passwords in the password manager |

## 1. Control node, once

The control node's own setup. Its NixOS configuration isn't in this repo.

### Nix settings for the tests

**On:** control node.

Flakes must be enabled before `nix develop` works, and the nspawn tests of `just test`
need the other settings. Add them to the control node's own NixOS configuration, then run
`sudo nixos-rebuild switch` there:

```nix
nix.settings = {
  experimental-features = [ "nix-command" "flakes" "auto-allocate-uids" ];
  auto-allocate-uids = true;
  system-features = [ "nixos-test" "benchmark" "big-parallel" "kvm" "uid-range" ];
};
```

### Dev shell

**On:** control node.

Needs flakes, enabled by the [Nix settings](#nix-settings-for-the-tests) above.

```bash
nix develop
```

It provides `just`, `sops`, `age`, `ssh-to-age`, `mkpasswd` and the formatters, and
installs the Git pre-commit hook. With [direnv](https://direnv.net), run `direnv allow`
once instead and it loads automatically.

### Control-node SSH key

**On:** control node.

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

**On:** control node.

Edits secrets. Its public half is the first recipient in `.sops.yaml`
(`age1h2xv8av7hpl4y0kyuq2yup24unl29ch8dvzpa4mamwe4vpe22pjsa8e6u3`). Restore the file from
your backup on a new machine:

```bash
mkdir -p ~/.config/sops/age
```

Copy the backup to `~/.config/sops/age/keys.txt`. Back it up whenever it changes. See
[Admin age key lost](#admin-age-key-lost) if there is no backup.

### Deploy signing key

**On:** control node.

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

## 2. Repo, once

### Login passwords

**On:** control node.

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

**On:** control node.

If `secrets/<host>.yaml` is missing, create it with random Pi-hole, Grafana and ntfy
passwords, encrypted for the admin key only. It never replaces a file. `secrets/tcyclops.yaml` and
`secrets/dcyclops.yaml` already exist.

```bash
just secrets-init <host>
```

### Install a VM

Do this once per VM, on the Hyper-V PC, from NixOS-WSL. The ISO installs the SSH key from
`modules/nixos/common.nix`, and sets the console passwords from `users/<name>.hash`, so do
[Login passwords](#login-passwords) first.

1. **On:** control node (NixOS-WSL), then Windows. Build the ISO, then create and start the
   VM. Approve the UAC prompt on the Windows desktop, because the scripts in
   `scripts/hyper-v/` need administrator rights:

   ```bash
   just vm create tcyclops
   ```

   The ISO **wipes the disk with no prompt**. It only checks that it runs under Hyper-V, so
   attach it only to its own VM, never to a Debian one. The ISO goes in your Windows
   Downloads folder. To put it elsewhere on a Windows drive:
   `just iso_dir=/mnt/e/isos vm create tcyclops`. Pass `-Force` or `-Reinstall` after the VM
   name for those script options.

2. **On:** control node (NixOS-WSL), then Windows. Enable forwarding on the new switches,
   with another UAC prompt:

   ```bash
   just vm forwarding
   ```

3. [Rekey and deploy](#rekey-and-deploy).

To throw away `dcyclops` and start again, which is refused for `tcyclops`, run this on the
control node (NixOS-WSL), then Windows:

```bash
just vm rebuild dcyclops
```

A VM installed before a layout change in `modules/nixos/hyperv-lvm.nix` must be reinstalled
from a new ISO before its next deploy.

### Rekey and deploy

**On:** control node, except the fingerprint check, which is on the host console. Rekeying
or deploying to `tcyclops` or `dcyclops` needs NixOS-WSL.

A new install has a new SSH host key, so it can't decrypt `secrets/<host>.yaml` yet, and
its Pi-hole, Grafana and ntfy containers keep restarting until you rekey. `just deploy`
refuses until it is done. Do this after every install, including `just vm rebuild`:

```bash
just secrets-rekey tcyclops
```

It fetches the host's public key over SSH and shows its fingerprint. On the host console,
run `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` and compare, because a first
connection can't prove whose key it is. Then deploy:

```bash
just deploy tcyclops
```

Commit the changed `.sops.yaml` and `secrets/<host>.yaml`. Deploy later changes to a VM
first.

### Move an existing host here

**On:** control node, except step 6.

Run the steps on the control node, except step 6, which is on the host console, in this
order. Steps 3 and 4 need NixOS-WSL for a VM.

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
6. **On:** host. Delete what the old design left in the containers' state, which
   is now unused:
   `pihole/var/lib/pihole/web-password.env` and
   `grafana/var/lib/grafana/{admin-password,secret-key}` under
   `/var/lib/nixos-containers/`.

## 4. Per phone

Set up [ntfy](README.md#alerts-ntfy) alerts on Android, once per host. Steps 1 and 3 are on
the phone, 2 and 4 on the control node (NixOS-WSL for `tcyclops` or `dcyclops`), and the
fingerprint check in 3 on the host console:

1. **On:** phone. Install the ntfy app.
2. **On:** control node. Get the certificate and send it to the phone. It's public, but
   only root can read it on the host, so this asks for `captain`'s sudo password:

   ```bash
   just ntfy-cert dcyclops > ntfy.pem
   ```

3. **On:** phone, then host console. In the app, open Settings, Advanced, Manage certificates and import `ntfy.pem` (needs
   app 1.22.2 or newer). Compare the SHA-256 fingerprint it shows with the one printed on
   the host's console by:

   ```bash
   sudo openssl x509 -noout -fingerprint -sha256 -in /var/lib/nixos-containers/ntfy/var/lib/private/ntfy-sh/tls.crt
   ```

   The certificate is made again when the address changes or it nears expiry, so import it
   again then.
4. **On:** control node. Print the password:

   ```bash
   sops -d --extract '["ntfy-phone-password"]' secrets/dcyclops.yaml
   ```

5. **On:** phone. Subscribe to topic `alerts` on the host's own ntfy address (see
   [Service addresses](README.md#service-addresses)), such as `https://172.16.1.5` for
   `dcyclops`, with user `phone` and that password.

The VMs' addresses are behind the Hyper-V NAT switch, so a phone on the home Wi-Fi can't
reach them as they are. On Windows, add a route on the PC and tell the router, or map the port
on Windows with `netsh interface portproxy` to the address and give the phone the PC's
address instead, which also changes what the certificate must say. The iOS app only gets
alerts when it polls, which is delayed.

## 5. Recurring

| When                              | Where                                       | Do                                                                |
| --------------------------------- | ------------------------------------------- | ----------------------------------------------------------------- |
| After a NixOS-WSL restart         | Control node (NixOS-WSL), then Windows      | `just vm forwarding`, because Windows resets forwarding on the WSL adapter |
| Changing a login password         | Control node                                | `just set-password <user>`, commit, deploy                        |
| Changing a service password       | Control node                                | [Edit the secrets](#service-passwords), deploy                    |
| After reinstalling a host         | Control node, and host console              | [Rekey and deploy](#rekey-and-deploy)                             |
| After a compromise                | Control node                                | [Rotate the secrets](#after-a-compromise)                         |

### Service passwords

**On:** control node.

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

**On:** control node.

Rekeying doesn't change the values, and the old ciphertext stays in git history. After
reinstalling a compromised host, or if a key leaked, rekey, then change the values with
`sops secrets/<host>.yaml` and deploy. If the backup signing key was used on an untrusted
machine or leaked, replace it as in [Deploy signing key](#deploy-signing-key).

## 6. Recovery

### Main signing key leaked or lost

**On:** control node.

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

**On:** control node, then host console, as marked below.

Deploys fail with "lacks a signature by a trusted key", because the hosts trust only the old
public key. A normal deploy can't deliver the new key, so:

1. On the control node, move the old key aside, run `just signing-key`, and commit the new
   public file.
2. Build the host and copy its closure over as a file, then import it on the host as root,
   which needs no signature. The first three commands run on the control node, the rest
   on the host console:

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

**On:** control node.

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
