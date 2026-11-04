# Adopted Anduril NixOS STIG findings. See stig-audit.md for what was skipped and why.
{
  config,
  lib,
  pkgs,
  utils,
  ...
}:
let
  allArches = rule: [
    "-a always,exit -F arch=b32 ${rule}"
    "-a always,exit -F arch=b64 ${rule}"
  ];
  byUser = "-F auid>=1000 -F auid!=unset";
  noticeText = "Authorized use only. Activity on this system is logged.";

  # V-268081. Added as rules, because the STIG's fix replaces the whole PAM file. The
  # timed unlock differs from its unlock_time=0, which needs an admin, and root is locked.
  faillockArgs = [
    "deny=3"
    "fail_interval=900"
    "unlock_time=900"
  ];
  faillockModule = "${pkgs.pam}/lib/security/pam_faillock.so";
  faillock = name: {
    failDelay = {
      enable = true;
      delay = 4000000;
    };
    rules = {
      auth = {
        faillock_preauth = {
          order = config.security.pam.services.${name}.rules.auth.unix.order - 10;
          control = "required";
          modulePath = faillockModule;
          args = [ "preauth" ] ++ faillockArgs;
        };
        faillock_authfail = {
          order = config.security.pam.services.${name}.rules.auth.unix.order + 10;
          control = "[default=die]";
          modulePath = faillockModule;
          args = [ "authfail" ] ++ faillockArgs;
        };
      };
      account.faillock = {
        order = config.security.pam.services.${name}.rules.account.unix.order - 10;
        control = "required";
        modulePath = faillockModule;
      };
    };
  };

  # V-268170. A rule, for the same reason as faillock. use_authtok stops pam_unix asking
  # again, which would skip the quality check.
  pwquality = name: {
    rules.password = {
      pwquality = {
        order = config.security.pam.services.${name}.rules.password.unix.order - 10;
        control = "requisite";
        modulePath = "${pkgs.libpwquality.lib}/lib/security/pam_pwquality.so";
      };
      unix.settings.use_authtok = true;
    };
  };
in
{
  # V-268080, V-268090, V-268092. The audit module adds the package and audit=1.
  security.audit = {
    enable = true;
    # V-268093. The module passes this to the kernel too.
    backlogLimit = 8192;
    rules = [
      # V-268119
      "--loginuid-immutable"

      # V-268164, V-268165. These use real store paths, because the STIG's /run/current-system
      # paths are symlinks. No chcon: it's the multicall coreutils binary, so a rule on it
      # would fire on every coreutils command.
      "-a always,exit -F path=${pkgs.shadow}/bin/usermod -F perm=x ${byUser} -k privileged-usermod"
      "-a always,exit -F path=${pkgs.shadow}/bin/chage -F perm=x ${byUser} -k privileged-chage"

      # V-268097. Nothing uses cron, but the activation script below creates the directory.
      "-w /var/cron/tabs/ -p wa -k services"
      "-w /var/cron/cron.allow -p wa -k services"
      "-w /var/cron/cron.deny -p wa -k services"

      # V-268166. Logins go to lastlog2.db, because pam_lastlog2 replaces the old file.
      "-w /var/log/lastlog -p wa -k logins"
      "-w /var/lib/lastlog/lastlog2.db -p wa -k logins"

      # V-268167. The pwquality.conf below creates /etc/security, which this watch needs.
      "-w /etc/sudoers -p wa -k identity"
      "-w /etc/passwd -p wa -k identity"
      "-w /etc/shadow -p wa -k identity"
      "-w /etc/gshadow -p wa -k identity"
      "-w /etc/group -p wa -k identity"
      "-w /etc/security/opasswd -p wa -k identity"
    ]
    ++ lib.concatMap allArches [
      # V-268091, V-268148
      "-S execve -C uid!=euid -F euid=0 -k execpriv"
      "-S execve -C gid!=egid -F egid=0 -k execpriv"
      # V-268094
      "-S mount ${byUser} -k privileged-mount"
      # V-268096
      "-S init_module,finit_module,delete_module ${byUser} -k module_chng"
      # V-268099
      "-S chown,fchown,lchown,fchownat ${byUser} -k perm_mod"
      # V-268100
      "-S chmod,fchmod,fchmodat ${byUser} -k perm_mod"
      # V-268095
      "-S rename,unlink,rmdir,renameat,unlinkat ${byUser} -k delete"
      # V-268098
      "-S open,creat,truncate,ftruncate,openat,open_by_handle_at -F exit=-EACCES ${byUser} -k access"
      "-S open,creat,truncate,ftruncate,openat,open_by_handle_at -F exit=-EPERM ${byUser} -k access"
      # V-268163
      "-S setxattr,fsetxattr,lsetxattr,removexattr,fremovexattr,lremovexattr ${byUser} -k perm_mod"
      "-S setxattr,fsetxattr,lsetxattr,removexattr,fremovexattr,lremovexattr -F auid=0 -k perm_mod"
    ];
  };

  security.auditd = {
    enable = true;
    settings = {
      # V-268101 to V-268104
      space_left = "25%";
      space_left_action = "syslog";
      admin_space_left = "10%";
      admin_space_left_action = "syslog";
      # V-268105, V-268106. SYSLOG, because the STIG's HALT stops the host on a full disk.
      disk_full_action = "SYSLOG";
      disk_error_action = "SYSLOG";
      # V-268110
      log_group = "root";
    };
  };

  services.openssh.settings = {
    # V-268088
    LogLevel = "VERBOSE";
    # V-268142, V-268143
    ClientAliveInterval = 600;
    ClientAliveCountMax = 1;
    # V-268083. Plain wording, because the STIG's required text is a US DoW notice.
    Banner = "${pkgs.writeText "ssh-banner" "${noticeText}\n"}";
  };

  # V-268082
  services.getty.helpLine = noticeText;

  # V-268107
  services.journald.settings.Journal.Audit = true;

  security.pam = {
    services = lib.mkMerge [
      (lib.genAttrs [ "login" "sshd" ] faillock)
      (lib.genAttrs [ "passwd" "chpasswd" "sudo" ] pwquality)
    ];
    # V-268085
    loginLimits = [
      {
        domain = "*";
        item = "maxlogins";
        type = "hard";
        value = "10";
      }
    ];
  };

  environment.etc = {
    # V-268126 to V-268129, V-268134, V-268145, V-268169
    "security/pwquality.conf".text = ''
      ucredit=-1
      lcredit=-1
      dcredit=-1
      ocredit=-1
      difok=8
      minlen=15
      dictcheck=1
    '';
    # V-268174. Keeps the other nixpkgs defaults, which the STIG's fix drops.
    "default/useradd".text = lib.mkForce ''
      GROUP=100
      HOME=${config.users.defaultUserHome}
      SHELL=${utils.toShellPath config.users.defaultUserShell}
      INACTIVE=35
    '';
    # V-268153
    "aide.conf".text = ''
      database_in=file:/var/lib/aide/aide.db
      database_out=file:/var/lib/aide/aide.db.new
      Norm = p+i+n+u+g+s+m+sha512
      /boot Norm
      /etc Norm
      !/etc/mtab
    '';
  };

  # V-268132, V-268133, V-268171
  security.loginDefs.settings = {
    PASS_MIN_DAYS = "1";
    PASS_MAX_DAYS = "180";
    FAIL_DELAY = "4";
  };

  # V-268155
  security.sudo.extraConfig = "Defaults timestamp_timeout=0";

  # V-268173
  security.apparmor.enable = true;

  # V-268139. Devices present at boot stay allowed, so a plugged-in keyboard keeps working.
  services.usbguard = {
    enable = true;
    presentDevicePolicy = "allow";
  };

  # V-268087, V-268153
  environment.systemPackages = [
    pkgs.vlock
    pkgs.aide
  ];

  # V-268153. A timer and the journal instead of the STIG's cron and mail. Differences
  # fail the unit. After a deploy, delete the database to accept the new baseline.
  systemd.services.aide = {
    description = "AIDE integrity check";
    serviceConfig = {
      Type = "oneshot";
      StateDirectory = "aide";
      StateDirectoryMode = "0700";
    };
    script = ''
      if [ ! -e /var/lib/aide/aide.db ]; then
        ${pkgs.aide}/bin/aide -c /etc/aide.conf --init
        mv /var/lib/aide/aide.db.new /var/lib/aide/aide.db
      else
        ${pkgs.aide}/bin/aide -c /etc/aide.conf --check
      fi
    '';
  };
  systemd.timers.aide = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "weekly";
      Persistent = true;
    };
  };

  # V-268097, V-268166. A watch can't load if its parent directory is missing.
  system.activationScripts.auditWatchDirs.text = "mkdir -p /var/cron/tabs /var/lib/lastlog";

  # V-268158. Limits new SSH connections per address. Runs before the firewall, because
  # extraInputRules comes after its SSH accept. The STIG's byte limit would hit deploys.
  networking.nftables.tables.ssh-limit = {
    family = "inet";
    content = ''
      set new_connections {
        type ipv4_addr
        flags dynamic, timeout
        timeout 5m
      }

      chain input {
        type filter hook input priority filter - 1; policy accept;

        tcp dport 22 ct state new add @new_connections { ip saddr limit rate over 30/minute } drop
      }
    '';
  };

  # V-268152
  nix.settings.allowed-users = [
    "root"
    "@wheel"
  ];

  boot.kernel.sysctl = {
    # V-268141
    "net.ipv4.tcp_syncookies" = 1;
    # V-268161
    "kernel.randomize_va_space" = 2;
  };
}
