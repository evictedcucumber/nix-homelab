# Anduril NixOS STIG audit

Every finding in the Anduril NixOS STIG (V1R3, 30 Sep 2026) compared with this flake. The adopted findings are in `modules/nixos/hardening.nix`, which is built and evaluated but **not yet deployed to any host**.

`modules/nixos/common.nix` applies to all three hosts, and none of them adds hardening of its own, so each result covers `cyclops`, `tcyclops` and `dcyclops` unless the note says otherwise.

## Summary

| Status | Findings | Meaning |
|---|---:|---|
| Implemented | 50 | In `hardening.nix`, not yet deployed |
| Partial | 5 | In `hardening.nix`, but differs from the STIG; see the notes |
| Met | 5 | Set in `common.nix`, or met another way |
| Default | 11 | Not set here; relies on a NixOS default |
| Gap | 10 | Not met as the STIG words it |
| Host check | 16 | Can only be confirmed on a running host or the control node |
| N/A | 6 | The feature isn't in use |

| Recommendation | Findings | Meaning |
|---|---:|---|
| Test | 55 | In `hardening.nix`; test on `tcyclops` |
| Adopt | 1 | Still to do: the control-node key passphrase |
| Consider | 2 | Depends on your setup, or needs testing first |
| Skip | 11 | DoW-specific, weaker than what you have, poor value, or declined |
| Check | 14 | Look on a host, then decide |
| Keep | 20 | Nothing to change |

The recommendations are my judgement, not part of the STIG. Passing this audit wouldn't mean STIG compliance, since 11 findings are deliberately skipped and 5 differ from its wording.

## Gaps the STIG doesn't cover

- **Shared default password (closed):** `captain` and `riley` have their own yescrypt hash in `users/<name>.hash`, made by `just set-password`, and `common.nix` fails the build if one is missing or isn't yescrypt. Nothing shares a password or sits in the Nix store as plaintext. The hashes are public, so only a strong password protects them. The Grafana, ntfy and Pi-hole passwords are random and encrypted with sops-nix.
- **Root-equivalent Nix access (closed):** only root is a trusted Nix user, so `captain` can add a store path only if it is signed by the deploy key in `keys/`. The `nix-signing` test checks this. Anyone holding the private key can still have a host accept any closure. The STIG never mentions `trusted-users`.

## Limits of this audit

- **Source:** the findings come from the XCCDF-derived JSON in the third-party `nealfennimore/nixos-stig-anduril` repo. It wasn't compared with DISA's own file, because public.cyber.mil wasn't reached.
- **Defaults:** defaults were read from nixpkgs source at the locked revision `0bb2eed`, not evaluated. The values the notes mark as confirmed were also checked with `nix eval`.
- **cyclops:** its `hardware-configuration.nix` is still a placeholder, and its network config isn't in the repo.
- **Option names:** several STIG fixes use old or invalid option paths. Check each against current nixpkgs before use. The notes give the current name where I checked it.
- **Untested behaviour:** none of `hardening.nix` has run on a host, including the audit rules, PAM stacks, firewall rule, USBGuard, AppArmor and AIDE. Notes on the effects of `fips=1` and on audit rule paths are reasoning, not test results.

## All findings

Sorted by severity (CAT), then ID.

| Finding | CAT | Requirement | Status | Recommendation | Notes |
|---|---|---|---|---|---|
| V-268089 | I | Implement DoW-approved encryption to protect the confidentiality of remote access sessions. | Gap | Skip | The default list also has chacha20-poly1305 and AES-GCM. The STIG allows CTR modes only, which would remove the stronger ciphers. Drop the CTR modes instead if you want to tighten this. |
| V-268130 | I | Store only encrypted representations of passwords. | Default | Keep | The default is `YESCRYPT`, stronger than the SHA-512 baseline, though a literal check for `SHA512` would flag it. Don't downgrade. |
| V-268131 | I | Not have the telnet package installed. | Default | Check | The repo adds no telnet package, and I found none in the base modules I read. Confirm with `whereis telnet` on a host. |
| V-268144 | I | Protect the confidentiality and integrity of all information at rest. | Gap | Skip | Your decision on 2026-11-04: no disk encryption for now. Adding LUKS to cyclops after install means a reinstall. |
| V-268146 | I | Protect wireless access to and from the system using encryption. | Default | Keep | `false`, confirmed with `nix eval`. |
| V-268154 | I | Prevent the installation of patches, service packs, device drivers, or operating system comp… | Default | Consider | `require-sigs` is on and only root is trusted, so `captain` can add only closures signed by the deploy key. Deploys sign them on the control node. Covered by the `nix-signing` test. |
| V-268157 | I | Implement cryptographic mechanisms to protect the integrity of nonlocal maintenance and diag… | Gap | Skip | The defaults are the ETM variants of these MACs plus `umac-128-etm`. The STIG's non-ETM list is weaker, and AEAD ciphers don't use a separate MAC anyway. |
| V-268159 | I | Protect the confidentiality and integrity of transmitted information. | Met | Keep | `services.openssh.enable = true`: `common.nix:44`. |
| V-268168 | I | Implement NIST FIPS-validated cryptography for the following: to provision digital signature… | Gap | Skip | `fips=1` doesn't make a NixOS system FIPS-validated, and it may break things like ed25519 keys, which your SSH setup relies on. Only relevant if you have a compliance requirement. |
| V-268172 | I | Not allow an unattended or automatic logon to the system via the console. | Default | Keep | No autologin setting in the repo, `services.getty.autologinUser` evaluates to null, and there's no GUI. |
| V-268176 | I | Employ strong authenticators in the establishment of nonlocal maintenance and diagnostic ses… | Default | Keep | `UsePAM` is on by default. Publickey is still the only login method, per `common.nix:54`. |
| V-268078 | II | Enable the built-in firewall. | Default | Keep | `networking.firewall.enable` defaults to true, on the nftables backend. `firewall.nix` denies everything in, out and forward except inbound SSH and outbound NTP, NTS and DNS over TLS. `modules/containers/framework/lan.nix` also forwards inbound DNS and HTTP(S) from private addresses to the Pi-hole container, on an address of its own, and does the same for HTTPS to the Grafana and ntfy containers. |
| V-268079 | II | NixOS emergency or temporary user accounts must be provisioned with an expiration time of 72… | N/A | Keep | No temporary or emergency accounts: only `captain` and `riley` are declared. |
| V-268080 | II | Enable the audit daemon. | Implemented | Test | Neither `security.audit.enable` nor `security.auditd.enable` is set. Most of the audit findings depend on this. |
| V-268081 | II | Enforce the limit of three consecutive invalid logon attempts by a user during a 15-minute t… | Partial | Test | Rules added to the `login` and `sshd` PAM stacks, not the STIG's whole-file replacement. `unlock_time=900` differs from its `unlock_time=0`, because root is locked and nobody could clear a lockout. Inert on `sshd`, whose publickey logins never run the auth stack, and each SSH login resets the console failure count. `sudo` isn't covered, so a mistyped deploy password can't lock `captain`. |
| V-268082 | II | Be configured to display the Standard Mandatory DoW Notice and Consent Banner before grantin… | Partial | Test | Console notice through `services.getty.helpLine`. Plain authorized-use text, because the required DoW wording would present this as a US government system. |
| V-268083 | II | Be configured to display the Standard Mandatory DoW Notice and Consent Banner before grantin… | Partial | Test | Same plain text as V-268082, set with `services.openssh.settings.Banner`. |
| V-268084 | II | Be configured to display the Standard Mandatory DoW Notice and Consent Banner before grantin… | N/A | Keep | No graphical login. |
| V-268086 | II | Initiate a session lock after a 10-minute period of inactivity for graphical user logon. | N/A | Keep | The fix is for GNOME, GDM and xautolock, and these hosts have no GUI. |
| V-268087 | II | Provide the capability for users to directly initiate a session lock for all connection types. | Implemented | Test | `pkgs.vlock` is installed. It only helps at a physical console, so mainly on cyclops. |
| V-268088 | II | Monitor remote access methods. | Implemented | Test | Set `services.openssh.settings.LogLevel = "VERBOSE"`. It logs the key fingerprint used for each login. |
| V-268090 | II | The NixOS audit package must be installed. | Implemented | Test | Added by the nixpkgs audit module. |
| V-268091 | II | Generate audit records for all usage of privileged commands. | Implemented | Test | Audit rule for commands run with elevated privileges. |
| V-268092 | II | Enable auditing of processes that start prior to the audit daemon. | Implemented | Test | Added by the nixpkgs audit module. |
| V-268093 | II | Allocate an audit_backlog_limit of sufficient size to capture processes that start prior to… | Implemented | Test | `security.audit.backlogLimit = 8192`. The nixpkgs audit module passes it to the kernel too. |
| V-268094 | II | Successful/unsuccessful uses of the mount syscall in NixOS must generate an audit record. | Implemented | Test | Audit rule. |
| V-268095 | II | Successful/unsuccessful uses of the rename, unlink, rmdir, renameat, and unlinkat system cal… | Implemented | Test | Audit rule. Noisy: it logs every delete by a logged-in user, so check the volume on tcyclops. |
| V-268096 | II | Successful/unsuccessful uses of the init_module, finit_module, and delete_module system call… | Implemented | Test | Audit rule for kernel module changes. |
| V-268097 | II | Generate an audit record for successful/unsuccessful modifications to the cron configuration. | Implemented | Test | Watches on `/var/cron`, with an activation script creating the directory so the rules load. Cosmetic, because nothing here uses cron. |
| V-268098 | II | Generate an audit record for successful/unsuccessful uses of the truncate, ftruncate, creat,… | Implemented | Test | Audit rules for `EACCES` and `EPERM`. Noisy: they log every denied file access, so check the volume on tcyclops. |
| V-268099 | II | Successful/unsuccessful uses of the chown, fchown, fchownat, and lchown system calls in NixO… | Implemented | Test | Audit rule. |
| V-268100 | II | Successful/unsuccessful uses of the chmod, fchmod, and fchmodat system calls in NixOS must g… | Implemented | Test | Audit rule. |
| V-268101 | II | Notify the system administrator (SA) and information system security officer (ISSO) (at a mi… | Implemented | Test | Set in `security.auditd.settings`, not the STIG's `environment.etc`. |
| V-268102 | II | Notify the system administrator (SA) and information system security officer (ISSO) (at a mi… | Implemented | Test | Same as V-268101. |
| V-268103 | II | Take action when allocated audit record storage volume reaches 75 percent of the repository… | Implemented | Test | Same as V-268101. |
| V-268104 | II | Take action when allocated audit record storage volume reaches 90 percent of the repository… | Implemented | Test | Same as V-268101. |
| V-268105 | II | The NixOS audit system must take appropriate action when the audit storage volume is full. | Implemented | Test | Choose `SYSLOG`, which the STIG allows. Its example, `HALT`, stops the server when the audit disk fills. |
| V-268106 | II | The NixOS audit system must take appropriate action when an audit processing failure occurs. | Implemented | Test | Choose `SYSLOG`, for the same reason as V-268105. |
| V-268107 | II | Have the packages required for offloading audit logs installed and running. | Implemented | Test | `services.journald.settings.Journal.Audit = true`. Check how it behaves alongside auditd. |
| V-268108 | II | The NixOS audit records must be off-loaded onto a different system or storage media from the… | Gap | Skip | Loki runs on the same host, so root can still erase the records. Needs a log server on a different system. |
| V-268109 | II | Authenticate the remote logging server for off-loading audit logs. | Gap | Skip | Depends on V-268108. |
| V-268110 | II | NixOS audit daemon must generate logs that are group-owned by root. | Implemented | Test | Set `log_group = root` in `security.auditd.settings`. |
| V-268111 | II | NixOS audit directory and logs must be owned by root to prevent unauthorized read access. | Host check | Check | Only exists once auditd is running. |
| V-268112 | II | NixOS audit directory and logs must be group-owned by root to prevent unauthorized read access. | Host check | Check | Only exists once auditd is running. |
| V-268113 | II | NixOS audit log directory must have a mode of 0700 or less permissive. | Host check | Check | Only exists once auditd is running. |
| V-268114 | II | NixOS audit logs must have a mode of 0600 or less permissive. | Host check | Check | Only exists once auditd is running. |
| V-268115 | II | NixOS journald directory and logs must be owned by root to prevent unauthorized read access. | Host check | Check | Check file ownership under `/var/log/journal`. The STIG's fix text says `/var/log/journald`, a different path from the one its related check uses. |
| V-268116 | II | NixOS journald directory and logs must be group-owned by systemd-journald to prevent unautho… | Host check | Check | Check the group under `/var/log/journal`. |
| V-268117 | II | NixOS systemd-journald directory must have a mode of 2755 or less permissive. | Host check | Check | Check directory modes under `/var/log/journal`. |
| V-268118 | II | NixOS systemd-journald logs must have a mode of 0640 or less permissive. | Host check | Check | Check file modes under `/var/log/journal`. |
| V-268119 | II | NixOS audit system must protect logon UIDs from unauthorized change. | Implemented | Test | Add `--loginuid-immutable` to the audit rules. |
| V-268120 | II | NixOS audit configuration files must have a mode of 444 or less permissive. | Host check | Check | Check `/etc/audit` once auditd is enabled. |
| V-268121 | II | NixOS system configuration file directories must have a mode of "0755" or less permissive. | Host check | Check | Check `/etc/audit` once auditd is enabled. |
| V-268122 | II | NixOS system configuration files and directories must be owned by root. | Host check | Check | Check `/etc/audit` once auditd is enabled. |
| V-268123 | II | NixOS system configuration files and directories must be group-owned by root. | Host check | Check | Check `/etc/audit` once auditd is enabled. |
| V-268124 | II | NixOS, for PKI-based authentication, must validate certificates by constructing a certificat… | N/A | Keep | Requires DoW PKI certificates. |
| V-268125 | II | Enforce authorized access to the corresponding private key for PKI-based authentication. | Host check | Adopt | Applies to your control node, and not yet checked. Confirm `~/.ssh/nix-homelab-control-node.key` has a passphrase, because it's the only SSH route into every host. |
| V-268126 | II | Enforce password complexity by requiring that at least one uppercase character be used. | Implemented | Test | `ucredit=-1` in `/etc/security/pwquality.conf`, enforced through V-268170. |
| V-268127 | II | Enforce password complexity by requiring that at least one lowercase character be used. | Implemented | Test | `lcredit=-1`, as V-268126. |
| V-268128 | II | Enforce password complexity by requiring that at least one numeric character be used. | Implemented | Test | `dcredit=-1`, as V-268126. |
| V-268129 | II | Require the change of at least 50 percent of the total number of characters when passwords a… | Implemented | Test | `difok=8`, as V-268126. |
| V-268132 | II | Enforce 24 hours/one day as the minimum password lifetime. | Implemented | Test | `PASS_MIN_DAYS` in `login.defs`. Only applies to accounts `useradd` creates, so not to `captain` or `riley`, whose shadow entries nixpkgs writes without aging fields. |
| V-268133 | II | Enforce a 180-day maximum password lifetime restriction. | Implemented | Test | `PASS_MAX_DAYS`, with the same limit as V-268132. |
| V-268134 | II | Enforce a minimum 15-character password length. | Implemented | Test | `minlen=15`, as V-268126. |
| V-268135 | II | Uniquely identify and must authenticate organizational users (or processes acting on behalf… | Met | Keep | Explicit, unique UIDs: `common.nix:70` and `common.nix:81`. |
| V-268136 | II | Use multifactor authentication for network access to privileged accounts. | Gap | Skip | `opencryptoki` is smart-card tooling. If you want real MFA, a FIDO2 `sk-ed25519` SSH key is the better fit. |
| V-268137 | II | Not allow direct login to the root account via SSH. | Met | Keep | `PermitRootLogin = "no"`: `common.nix:57`. |
| V-268138 | II | Not allow direct login to the root account. | Met | Keep | `users.mutableUsers = false` and root's `hashedPassword = "!"` in `common.nix` lock root on every activation. Confirm with `passwd -S root`. |
| V-268139 | II | Enable USBguard. | Implemented | Test | `services.usbguard` with `presentDevicePolicy = "allow"`. A USB device plugged in after the daemon starts is blocked until allowed, including a keyboard on cyclops. Anything present when the daemon restarts, such as during a deploy, is allowed. Generate a policy with `usbguard generate-policy` before relying on this on cyclops. |
| V-268140 | II | A sticky bit must be set on all NixOS public directories to prevent unauthorized and uninten… | Host check | Check | Run the STIG's `find` check for world-writable directories without the sticky bit. |
| V-268141 | II | Manage excess capacity, bandwidth, or other redundancy to limit the effects of information f… | Implemented | Test | The locked nixpkgs doesn't set this, so it's down to the kernel default. Set it explicitly, since it's one line. |
| V-268142 | II | Terminate all SSH connections after 10 minutes of becoming unresponsive. | Implemented | Test | Set `ClientAliveInterval = 600` under `services.openssh.settings`. |
| V-268143 | II | Terminate all SSH connections after becoming unresponsive. | Implemented | Test | Set `ClientAliveCountMax = 1`. |
| V-268145 | II | Enforce password complexity by requiring that at least one special character be used. | Implemented | Test | `ocredit=-1`, as V-268126. |
| V-268147 | II | Protect wireless access to the system using authentication of users and/or devices. | Default | Keep | `false`, confirmed with `nix eval`. |
| V-268148 | II | Prevent all software from executing at higher privilege levels than users executing the soft… | Implemented | Test | Comes with V-268080 and V-268091. |
| V-268149 | II | NixOS must, for networked systems, compare internal information system clocks at least every… | Gap | Skip | The required servers are US Navy ones. `time.cloudflare.com` with NTS, at `common.nix:12`, is right for you. |
| V-268150 | II | Synchronize internal information system clocks to the authoritative time source when the tim… | Gap | Skip | Polling public NTP servers every 60 seconds is excessive. Worth revisiting only with your own time server. |
| V-268151 | II | Have time synchronization enabled. | Met | Keep | `services.chrony.enable = true` at `common.nix:13` replaces `timesyncd`, and `firewall.nix` allows the outbound NTP, NTS and DNS over TLS it needs. |
| V-268152 | II | Prohibit user installation of system software without explicit privileged status. | Implemented | Test | Set `nix.settings.allowed-users = [ "root" "@wheel" ]`. The default is everyone, including `riley`. |
| V-268153 | II | Notify designated personnel if baseline configurations are changed in an unauthorized manner. | Implemented | Test | AIDE on `/boot` and `/etc`, run weekly by a systemd timer. It reports through the journal and a failed unit, not the STIG's cron and mail. Deploys change `/etc`, so delete `/var/lib/aide/aide.db` after one to accept the new baseline. |
| V-268155 | II | Require users to reauthenticate for privilege escalation. | Implemented | Test | `timestamp_timeout=0`. `nixos-rebuild` feeds the password to each `sudo` call, so deploys should still work; test this on tcyclops. |
| V-268156 | II | Require users to reauthenticate when changing roles. | Default | Keep | `security.sudo.wheelNeedsPassword` defaults to true. The repo doesn't change it. |
| V-268158 | II | Protect against or limit the effects of denial-of-service (DoS) attacks by ensuring the oper… | Partial | Test | Limits new SSH connections to 30 a minute per address, in a chain that runs before the firewall. The STIG's example appends to `INPUT`, after `nixos-fw` has already accepted the traffic, and its byte limit would throttle deploys. |
| V-268160 | II | Implement nonexecutable data to protect its memory from unauthorized code execution. | Default | Keep | nixpkgs `sysctl.nix:114` sets `kernel.kptr_restrict` to 1. |
| V-268161 | II | Implement address space layout randomization to protect its memory from unauthorized code ex… | Implemented | Test | The locked nixpkgs modules I read don't set this, so it's down to the kernel default. Set it explicitly, since it's one line. |
| V-268163 | II | Generate audit records when successful/unsuccessful attempts to modify security objects occur. | Implemented | Test | Audit rule. |
| V-268164 | II | Generate audit records when successful/unsuccessful attempts to delete privileges occur. | Implemented | Test | Uses the real `shadow` store path, because the STIG's `/run/current-system` path is a symlink. Test that it fires. |
| V-268165 | II | Generate audit records when successful/unsuccessful attempts to delete security objects occur. | Partial | Test | `chage` only, using its real store path. `chcon` is left out: it's the multicall `coreutils` binary, so a rule would fire on every coreutils command. |
| V-268166 | II | Generate audit records when concurrent logons to the same account occur from different sources. | Implemented | Test | Watches on `/var/log/lastlog` and `/var/lib/lastlog/lastlog2.db`. Logins are recorded in the second, because the login PAM stack uses `pam_lastlog2`. |
| V-268167 | II | Generate audit records for all account creations, modifications, disabling, and termination… | Implemented | Test | All the watches, now including `/etc/security/opasswd`, because `pwquality.conf` creates its parent directory. |
| V-268169 | II | Prevent the use of dictionary words for passwords. | Implemented | Test | `dictcheck=1`, as V-268126. Confirmed locally with `pwscore`, which rejected a dictionary word. |
| V-268170 | II | Enable the use of pwquality. | Implemented | Test | `pam_pwquality` rule on `passwd`, `chpasswd` and `sudo`, plus `use_authtok` on `pam_unix` so a second prompt can't skip the check. Not the STIG's text override, which replaces the whole stack. Root only gets a warning, because `enforce_for_root` isn't set, so `sudo passwd riley` can still set a weak password, though with `mutableUsers = false` it is lost on the next activation. A hash from `just set-password` skips pwquality, so that recipe checks the same rules. The rule on `sudo` has no effect, because nothing uses its password stack. |
| V-268171 | II | Enforce a delay of at least four seconds between logon prompts following a failed logon atte… | Implemented | Test | `FAIL_DELAY` in `login.defs`, plus a 4-second `pam_faildelay` on `login` and `sshd`. |
| V-268173 | II | Be configured to use AppArmor. | Implemented | Test | `security.apparmor.enable`. It needs a reboot, and does little without profiles for the services you run. |
| V-268174 | II | Disable account identifiers (individuals, groups, roles, and devices) after 35 days of inact… | Implemented | Test | `INACTIVE=35` in `/etc/default/useradd`, keeping the nixpkgs lines the STIG's fix drops. Only applies to accounts `useradd` creates. |
| V-268175 | II | Employ approved cryptographic hashing algorithms for all stored passwords. | Host check | Skip | The STIG wants `$6` (SHA-512) hashes, while your default produces stronger yescrypt. Don't downgrade. |
| V-268177 | II | Implement multifactor authentication for remote access to privileged accounts in such a way… | Gap | Skip | Smart-card login. See the FIDO2 note on V-268136. |
| V-268178 | II | Prohibit the use of cached authenticators after one day. | N/A | Keep | No SSSD. |
| V-268179 | II | For PKI-based authentication, NixOS must implement a local cache of revocation data to suppo… | N/A | Keep | No PKI login. |
| V-268180 | II | Run a supported release of the operating system. | Host check | Consider | Hosts track `nixos-unstable`, not a numbered release, so this depends on how you read "supported". Updates also only land when you bump `flake.lock` and deploy. |
| V-268181 | II | Define default permissions for all authenticated users in such a way that the user can only… | Default | Keep | `security.loginDefs.settings.UMASK` already evaluates to `077`, confirmed with `nix eval`. |
| V-268085 | III | Be configured to limit the number of concurrent sessions to 10 for all accounts and/or accou… | Implemented | Test | `security.pam.loginLimits` with a hard `maxlogins` of 10. |
