# Adopted Anduril NixOS STIG findings. See stig-audit.md for what was skipped and why.
{ lib, pkgs, ... }:
let
  allArches = rule: [
    "-a always,exit -F arch=b32 ${rule}"
    "-a always,exit -F arch=b64 ${rule}"
  ];
  byUser = "-F auid>=1000 -F auid!=unset";
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

      # V-268167, without /etc/security/opasswd: its parent directory may not exist, which
      # would stop auditctl loading the rules after it.
      "-w /etc/sudoers -p wa -k identity"
      "-w /etc/passwd -p wa -k identity"
      "-w /etc/shadow -p wa -k identity"
      "-w /etc/gshadow -p wa -k identity"
      "-w /etc/group -p wa -k identity"
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
