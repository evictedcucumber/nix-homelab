# Anduril NixOS STIG audit

Every finding in the Anduril NixOS STIG (V1R3, 30 Sep 2026) compared with this flake. The adopted findings are in `modules/nixos/hardening.nix`, which is built and evaluated but **not yet deployed to any host**.

`modules/nixos/common.nix` applies to all three hosts, and none of them adds hardening of its own, so each result covers `cyclops`, `tcyclops` and `dcyclops` unless the note says otherwise.

## Summary

| Status | Findings | Meaning |
|---|---:|---|
| Implemented | 26 | In `hardening.nix`, not yet deployed |
| Partial | 2 | In `hardening.nix` with a rule left out; see the notes |
| Met | 4 | Set in `common.nix`, or met another way |
| Default | 11 | Not set here; relies on a NixOS default |
| Gap | 38 | Not met as the STIG words it |
| Host check | 16 | Can only be confirmed on a running host or the control node |
| N/A | 6 | The feature isn't in use |

| Recommendation | Findings | Meaning |
|---|---:|---|
| Test | 28 | In `hardening.nix`; test on `tcyclops` |
| Adopt | 1 | Still to do: the control-node key passphrase |
| Consider | 15 | Depends on your setup, or needs testing first |
| Skip | 26 | DoW-specific, weaker than what you have, poor value, or declined |
| Check | 14 | Look on a host, then decide |
| Keep | 19 | Nothing to change |

The recommendations are my judgement, not part of the STIG. Passing this audit wouldn't mean STIG compliance, since 26 findings are deliberately skipped.

## Gaps the STIG doesn't cover

- **Shared default password:** `captain` and `riley` get the same `initialPassword` from `common.nix:5`. It's in the repo and readable in the Nix store, and nothing enforces changing it.
- **Root-equivalent Nix access:** `trusted-users = [ "@wheel" ]` at `common.nix:27` makes `captain` effectively root through the Nix daemon. The STIG never mentions `trusted-users`.

## Limits of this audit

- **Source:** the findings come from the XCCDF-derived JSON in the third-party `nealfennimore/nixos-stig-anduril` repo. It wasn't compared with DISA's own file, because public.cyber.mil wasn't reached.
- **Defaults:** defaults were read from nixpkgs source at the locked revision `0bb2eed`, not evaluated. The values the notes mark as confirmed were also checked with `nix eval`.
- **cyclops:** its `hardware-configuration.nix` is still a placeholder, and its network config isn't in the repo.
- **Option names:** several STIG fixes use old or invalid option paths. Check each against current nixpkgs before use. The notes give the current name where I checked it.
- **Untested behaviour:** the audit rules have never been loaded by a kernel. Notes on the effects of `fips=1` and on audit rule paths are reasoning, not test results.

## All findings

Sorted by severity (CAT), then ID.

| Finding | CAT | Requirement | Status | Recommendation | Notes |
|---|---|---|---|---|---|
| V-268089 | I | Implement DoW-approved encryption to protect the confidentiality of remote access sessions. | Gap | Skip | The default list also has chacha20-poly1305 and AES-GCM. The STIG allows CTR modes only, which would remove the stronger ciphers. Drop the CTR modes instead if you want to tighten this. |
| V-268130 | I | Store only encrypted representations of passwords. | Default | Keep | The default is `YESCRYPT`, stronger than the SHA-512 baseline, though a literal check for `SHA512` would flag it. Don't downgrade. |
| V-268131 | I | Not have the telnet package installed. | Default | Check | The repo adds no telnet package, and I found none in the base modules I read. Confirm with `whereis telnet` on a host. |
| V-268144 | I | Protect the confidentiality and integrity of all information at rest. | Gap | Skip | Your decision on 2026-11-04: no disk encryption for now. Adding LUKS to cyclops after install means a reinstall. |
| V-268146 | I | Protect wireless access to and from the system using encryption. | Default | Keep | `false`, confirmed with `nix eval`. |
| V-268154 | I | Prevent the installation of patches, service packs, device drivers, or operating system comp… | Default | Consider | `require-sigs` defaults to true, but `trusted-users = [ "@wheel" ]` at `common.nix:27` exists to accept unsigned closures, so `captain` bypasses it. Signing closures on the control node would close this. |
| V-268157 | I | Implement cryptographic mechanisms to protect the integrity of nonlocal maintenance and diag… | Gap | Skip | The defaults are the ETM variants of these MACs plus `umac-128-etm`. The STIG's non-ETM list is weaker, and AEAD ciphers don't use a separate MAC anyway. |
| V-268159 | I | Protect the confidentiality and integrity of transmitted information. | Met | Keep | `services.openssh.enable = true`: `common.nix:41`. |
| V-268168 | I | Implement NIST FIPS-validated cryptography for the following: to provision digital signature… | Gap | Skip | `fips=1` doesn't make a NixOS system FIPS-validated, and it may break things like ed25519 keys, which your SSH setup relies on. Only relevant if you have a compliance requirement. |
| V-268172 | I | Not allow an unattended or automatic logon to the system via the console. | Default | Keep | No autologin setting in the repo, `services.getty.autologinUser` evaluates to null, and there's no GUI. |
| V-268176 | I | Employ strong authenticators in the establishment of nonlocal maintenance and diagnostic ses… | Default | Keep | `UsePAM` is on by default. Publickey is still the only login method, per `common.nix:51`. |
| V-268078 | II | Enable the built-in firewall. | Default | Keep | `networking.firewall.enable` defaults to true, and only the SSH port opens. No hashlimit or other rules are set. |
| V-268079 | II | NixOS emergency or temporary user accounts must be provisioned with an expiration time of 72… | N/A | Keep | No temporary or emergency accounts: only `captain` and `riley` are declared. |
| V-268080 | II | Enable the audit daemon. | Implemented | Test | Neither `security.audit.enable` nor `security.auditd.enable` is set. Most of the audit findings depend on this. |
| V-268081 | II | Enforce the limit of three consecutive invalid logon attempts by a user during a 15-minute t… | Gap | Consider | No faillock. The STIG's `unlock_time=0` locks an account until an admin clears it, and root is locked, so use a timed unlock if you adopt this. |
| V-268082 | II | Be configured to display the Standard Mandatory DoW Notice and Consent Banner before grantin… | Gap | Skip | The required text is the US DoW notice, which doesn't apply to you. |
| V-268083 | II | Be configured to display the Standard Mandatory DoW Notice and Consent Banner before grantin… | Gap | Skip | Same DoW notice, for SSH. |
| V-268084 | II | Be configured to display the Standard Mandatory DoW Notice and Consent Banner before grantin… | N/A | Keep | No graphical login. |
| V-268086 | II | Initiate a session lock after a 10-minute period of inactivity for graphical user logon. | N/A | Keep | The fix is for GNOME, GDM and xautolock, and these hosts have no GUI. |
| V-268087 | II | Provide the capability for users to directly initiate a session lock for all connection types. | Gap | Consider | `vlock` only helps at a physical console, so it's only relevant to cyclops. |
| V-268088 | II | Monitor remote access methods. | Implemented | Test | Set `services.openssh.settings.LogLevel = "VERBOSE"`. It logs the key fingerprint used for each login. |
| V-268090 | II | The NixOS audit package must be installed. | Implemented | Test | Added by the nixpkgs audit module. |
| V-268091 | II | Generate audit records for all usage of privileged commands. | Implemented | Test | Audit rule for commands run with elevated privileges. |
| V-268092 | II | Enable auditing of processes that start prior to the audit daemon. | Implemented | Test | Added by the nixpkgs audit module. |
| V-268093 | II | Allocate an audit_backlog_limit of sufficient size to capture processes that start prior to… | Implemented | Test | `security.audit.backlogLimit = 8192`. The nixpkgs audit module passes it to the kernel too. |
| V-268094 | II | Successful/unsuccessful uses of the mount syscall in NixOS must generate an audit record. | Implemented | Test | Audit rule. |
| V-268095 | II | Successful/unsuccessful uses of the rename, unlink, rmdir, renameat, and unlinkat system cal… | Gap | Consider | Audit rule, but noisy: it logs every delete by a logged-in user. Check the volume on tcyclops. |
| V-268096 | II | Successful/unsuccessful uses of the init_module, finit_module, and delete_module system call… | Implemented | Test | Audit rule for kernel module changes. |
| V-268097 | II | Generate an audit record for successful/unsuccessful modifications to the cron configuration. | Gap | Skip | No cron in the repo. Scheduled jobs like the Nix GC use systemd timers. |
| V-268098 | II | Generate an audit record for successful/unsuccessful uses of the truncate, ftruncate, creat,… | Gap | Consider | Audit rule, but noisy: it logs every denied file access. Check the volume on tcyclops. |
| V-268099 | II | Successful/unsuccessful uses of the chown, fchown, fchownat, and lchown system calls in NixO… | Implemented | Test | Audit rule. |
| V-268100 | II | Successful/unsuccessful uses of the chmod, fchmod, and fchmodat system calls in NixOS must g… | Implemented | Test | Audit rule. |
| V-268101 | II | Notify the system administrator (SA) and information system security officer (ISSO) (at a mi… | Implemented | Test | Set in `security.auditd.settings`, not the STIG's `environment.etc`. |
| V-268102 | II | Notify the system administrator (SA) and information system security officer (ISSO) (at a mi… | Implemented | Test | Same as V-268101. |
| V-268103 | II | Take action when allocated audit record storage volume reaches 75 percent of the repository… | Implemented | Test | Same as V-268101. |
| V-268104 | II | Take action when allocated audit record storage volume reaches 90 percent of the repository… | Implemented | Test | Same as V-268101. |
| V-268105 | II | The NixOS audit system must take appropriate action when the audit storage volume is full. | Implemented | Test | Choose `SYSLOG`, which the STIG allows. Its example, `HALT`, stops the server when the audit disk fills. |
| V-268106 | II | The NixOS audit system must take appropriate action when an audit processing failure occurs. | Implemented | Test | Choose `SYSLOG`, for the same reason as V-268105. |
| V-268107 | II | Have the packages required for offloading audit logs installed and running. | Gap | Consider | The STIG's `services.journald.audit` is now `services.journald.settings.Journal.Audit` at your locked nixpkgs. Check how it behaves alongside auditd. |
| V-268108 | II | The NixOS audit records must be off-loaded onto a different system or storage media from the… | Gap | Skip | Needs a separate log server, and the repo has none. Revisit if you add one. |
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
| V-268126 | II | Enforce password complexity by requiring that at least one uppercase character be used. | Gap | Skip | Character-class rule. It has no effect unless V-268170 is also done, and modern guidance favours length. |
| V-268127 | II | Enforce password complexity by requiring that at least one lowercase character be used. | Gap | Skip | Same as V-268126. |
| V-268128 | II | Enforce password complexity by requiring that at least one numeric character be used. | Gap | Skip | Same as V-268126. |
| V-268129 | II | Require the change of at least 50 percent of the total number of characters when passwords a… | Gap | Skip | Same as V-268126. |
| V-268132 | II | Enforce 24 hours/one day as the minimum password lifetime. | Gap | Skip | Password age limits add little for two accounts, and SSH doesn't use passwords. |
| V-268133 | II | Enforce a 180-day maximum password lifetime restriction. | Gap | Skip | Same as V-268132. |
| V-268134 | II | Enforce a minimum 15-character password length. | Gap | Consider | The one password rule worth having, but it has no effect without V-268170. Using a long password yourself gets most of the benefit. |
| V-268135 | II | Uniquely identify and must authenticate organizational users (or processes acting on behalf… | Met | Keep | Explicit, unique UIDs: `common.nix:67` and `common.nix:78`. |
| V-268136 | II | Use multifactor authentication for network access to privileged accounts. | Gap | Skip | `opencryptoki` is smart-card tooling. If you want real MFA, a FIDO2 `sk-ed25519` SSH key is the better fit. |
| V-268137 | II | Not allow direct login to the root account via SSH. | Met | Keep | `PermitRootLogin = "no"`: `common.nix:54`. |
| V-268138 | II | Not allow direct login to the root account. | Met | Keep | Meets the check another way: `common.nix:90` locks root on every activation, instead of the STIG's `users.mutableUsers = false`. Confirm with `passwd -S root`. |
| V-268139 | II | Enable USBguard. | Gap | Consider | Not useful on the VMs. On cyclops it guards against physical USB attacks, but a bad policy can lock out your keyboard. |
| V-268140 | II | A sticky bit must be set on all NixOS public directories to prevent unauthorized and uninten… | Host check | Check | Run the STIG's `find` check for world-writable directories without the sticky bit. |
| V-268141 | II | Manage excess capacity, bandwidth, or other redundancy to limit the effects of information f… | Implemented | Test | The locked nixpkgs doesn't set this, so it's down to the kernel default. Set it explicitly, since it's one line. |
| V-268142 | II | Terminate all SSH connections after 10 minutes of becoming unresponsive. | Implemented | Test | Set `ClientAliveInterval = 600` under `services.openssh.settings`. |
| V-268143 | II | Terminate all SSH connections after becoming unresponsive. | Implemented | Test | Set `ClientAliveCountMax = 1`. |
| V-268145 | II | Enforce password complexity by requiring that at least one special character be used. | Gap | Skip | Same as V-268126. |
| V-268147 | II | Protect wireless access to the system using authentication of users and/or devices. | Default | Keep | `false`, confirmed with `nix eval`. |
| V-268148 | II | Prevent all software from executing at higher privilege levels than users executing the soft… | Implemented | Test | Comes with V-268080 and V-268091. |
| V-268149 | II | NixOS must, for networked systems, compare internal information system clocks at least every… | Gap | Skip | The required servers are US Navy ones. `za.pool.ntp.org` at `common.nix:12` is right for you. |
| V-268150 | II | Synchronize internal information system clocks to the authoritative time source when the tim… | Gap | Skip | Polling a public NTP pool every 60 seconds is excessive. Worth revisiting only with your own time server. |
| V-268151 | II | Have time synchronization enabled. | Default | Keep | `services.timesyncd.enable` defaults to true outside containers. |
| V-268152 | II | Prohibit user installation of system software without explicit privileged status. | Implemented | Test | Set `nix.settings.allowed-users = [ "root" "@wheel" ]`. The default is everyone, including `riley`. |
| V-268153 | II | Notify designated personnel if baseline configurations are changed in an unauthorized manner. | Gap | Skip | AIDE needs an overlay, a mail setup and tuning. Heavy for a homelab, and the Nix store is already read-only. |
| V-268155 | II | Require users to reauthenticate for privilege escalation. | Gap | Consider | `timestamp_timeout=0` prompts on every `sudo`. Test `just deploy-test` on tcyclops first, because deploys use `--ask-elevate-password`. |
| V-268156 | II | Require users to reauthenticate when changing roles. | Default | Keep | `security.sudo.wheelNeedsPassword` defaults to true. The repo doesn't change it. |
| V-268158 | II | Protect against or limit the effects of denial-of-service (DoS) attacks by ensuring the oper… | Gap | Consider | Only port 22 is open, so only that rule is relevant. `nix eval` shows nftables is off, so `extraCommands` would work. |
| V-268160 | II | Implement nonexecutable data to protect its memory from unauthorized code execution. | Default | Keep | nixpkgs `sysctl.nix:114` sets `kernel.kptr_restrict` to 1. |
| V-268161 | II | Implement address space layout randomization to protect its memory from unauthorized code ex… | Implemented | Test | The locked nixpkgs modules I read don't set this, so it's down to the kernel default. Set it explicitly, since it's one line. |
| V-268163 | II | Generate audit records when successful/unsuccessful attempts to modify security objects occur. | Implemented | Test | Audit rule. |
| V-268164 | II | Generate audit records when successful/unsuccessful attempts to delete privileges occur. | Implemented | Test | Uses the real `shadow` store path, because the STIG's `/run/current-system` path is a symlink. Test that it fires. |
| V-268165 | II | Generate audit records when successful/unsuccessful attempts to delete security objects occur. | Partial | Test | `chage` only, using its real store path. `chcon` is left out: it's the multicall `coreutils` binary, so a rule would fire on every coreutils command. |
| V-268166 | II | Generate audit records when concurrent logons to the same account occur from different sources. | Gap | Consider | Check that `/var/log/lastlog` actually exists on your hosts first. |
| V-268167 | II | Generate audit records for all account creations, modifications, disabling, and termination… | Partial | Test | All watches except `/etc/security/opasswd`: its parent directory may not exist, which would stop the remaining rules loading. |
| V-268169 | II | Prevent the use of dictionary words for passwords. | Gap | Skip | Same as V-268126. |
| V-268170 | II | Enable the use of pwquality. | Gap | Skip | The STIG's fix overrides PAM service text for `passwd`, `chpasswd` and `sudo`. A mistake could break `sudo` with root locked, and the benefit is small with two accounts. |
| V-268171 | II | Enforce a delay of at least four seconds between logon prompts following a failed logon atte… | Gap | Skip | Little benefit: SSH doesn't use passwords. |
| V-268173 | II | Be configured to use AppArmor. | Gap | Consider | Turning on `security.apparmor` does little without profiles for the services you run. Revisit when cyclops has real services. |
| V-268174 | II | Disable account identifiers (individuals, groups, roles, and devices) after 35 days of inact… | Gap | Skip | Applies to `useradd`, but your accounts are declared in Nix. |
| V-268175 | II | Employ approved cryptographic hashing algorithms for all stored passwords. | Host check | Skip | The STIG wants `$6` (SHA-512) hashes, while your default produces stronger yescrypt. Don't downgrade. |
| V-268177 | II | Implement multifactor authentication for remote access to privileged accounts in such a way… | Gap | Skip | Smart-card login. See the FIDO2 note on V-268136. |
| V-268178 | II | Prohibit the use of cached authenticators after one day. | N/A | Keep | No SSSD. |
| V-268179 | II | For PKI-based authentication, NixOS must implement a local cache of revocation data to suppo… | N/A | Keep | No PKI login. |
| V-268180 | II | Run a supported release of the operating system. | Host check | Consider | Hosts track `nixos-unstable`, not a numbered release, so this depends on how you read "supported". Updates also only land when you bump `flake.lock` and deploy. |
| V-268181 | II | Define default permissions for all authenticated users in such a way that the user can only… | Gap | Consider | `UMASK = "077"` is cheap, but makes new files private by default. Test it with anything shared between `captain` and `riley`. |
| V-268085 | III | Be configured to limit the number of concurrent sessions to 10 for all accounts and/or accou… | Gap | Consider | Low value with one SSH user. `security.pam.loginLimits` is a one-liner. |
