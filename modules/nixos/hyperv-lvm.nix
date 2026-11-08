# Disk layout for the managed Hyper-V VMs, all dynamic VHDX: a 512 GiB system disk for the
# OS, configuration and service data, and two 8 TiB data disks mirrored into one 8 TiB media
# array. Follows the separate file systems and mount options of the hardening benchmarks,
# plus /nix and the containers. Most of vg0 stays unassigned for growing a volume later.
{ lib, pkgs, ... }:
let
  noSpecial = [
    "nodev"
    "nosuid"
  ];
  noExec = noSpecial ++ [ "noexec" ];
  mediaMember = device: {
    inherit device;
    type = "disk";
    content = {
      type = "gpt";
      partitions.media = {
        size = "100%";
        content = {
          type = "mdraid";
          name = "media";
        };
      };
    };
  };
in
{
  disko.devices.disk.main.content.partitions.lvm = {
    size = "100%";
    content = {
      type = "lvm_pv";
      vg = "vg0";
    };
  };

  disko.devices.lvm_vg.vg0 = {
    type = "lvm_vg";
    lvs =
      lib.mapAttrs
        (
          _:
          {
            size,
            mountpoint,
            mountOptions ? [ "defaults" ],
          }:
          {
            inherit size;
            content = {
              type = "filesystem";
              format = "ext4";
              inherit mountpoint mountOptions;
            };
          }
        )
        {
          root = {
            size = "4G";
            mountpoint = "/";
          };
          nix = {
            size = "14G";
            mountpoint = "/nix";
            mountOptions = [ "noatime" ];
          };
          home = {
            size = "4G";
            mountpoint = "/home";
            mountOptions = noSpecial;
          };
          tmp = {
            size = "2G";
            mountpoint = "/tmp";
            mountOptions = noExec;
          };
          var = {
            size = "6G";
            mountpoint = "/var";
            mountOptions = noSpecial;
          };
          var_tmp = {
            size = "2G";
            mountpoint = "/var/tmp";
            mountOptions = noExec;
          };
          var_log = {
            size = "6G";
            mountpoint = "/var/log";
            mountOptions = noExec;
          };
          var_log_audit = {
            size = "2G";
            mountpoint = "/var/log/audit";
            mountOptions = noExec;
          };
          # Own volume so Loki can't fill /var. Container roots run setuid programs.
          containers = {
            size = "64G";
            mountpoint = "/var/lib/nixos-containers";
          };
        };
  };

  disko.devices.disk.media1 = mediaMember "/dev/sdb";
  disko.devices.disk.media2 = mediaMember "/dev/sdc";

  # Images, videos, ISOs and other large files. The members start as blank VHDX, so they
  # already match and --assume-clean skips the initial sync, which would fill both files.
  # XFS allocates inodes on demand, so the VHDX only grow with the data written.
  disko.devices.mdadm.media = {
    type = "mdadm";
    level = 1;
    metadata = "1.2";
    extraArgs = [ "--assume-clean" ];
    content = {
      type = "filesystem";
      format = "xfs";
      mountpoint = "/srv/media";
      mountOptions = noExec;
    };
  };

  # mdmonitor needs somewhere to report to. A degraded array also raises a Grafana alert.
  boot.swraid.mdadmConf = "PROGRAM ${pkgs.writeShellScript "mdadm-event" ''
    ${pkgs.util-linux}/bin/logger -t mdadm -p daemon.warning "$1 on $2 $3"
  ''}";

  # Members can write to it without sudo, and new files keep the group.
  users.groups.media.members = [
    "captain"
    "riley"
  ];
  systemd.tmpfiles.rules = [ "d /srv/media 2775 root media -" ];

  boot.specialFileSystems."/dev/shm".options = [ "noexec" ];
}
