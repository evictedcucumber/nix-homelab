# Disk layout for the managed Hyper-V VMs, both dynamic VHDX: a 256 GiB system disk for
# the OS, configuration and service data, and a 1 TiB data disk for media. Follows the
# separate file systems and mount options of the hardening benchmarks, plus /nix and the
# containers. Most of vg0 stays unassigned for growing a volume later.
{ lib, ... }:
let
  noSpecial = [
    "nodev"
    "nosuid"
  ];
  noExec = noSpecial ++ [ "noexec" ];
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

  disko.devices.disk.data = {
    device = "/dev/sdb";
    type = "disk";
    content = {
      type = "gpt";
      partitions.lvm = {
        size = "100%";
        content = {
          type = "lvm_pv";
          vg = "data";
        };
      };
    };
  };

  # Images, videos, ISOs and other large files. XFS allocates inodes on demand, so the
  # dynamic VHDX only grows with the data written.
  disko.devices.lvm_vg.data = {
    type = "lvm_vg";
    lvs.media = {
      size = "100%FREE";
      content = {
        type = "filesystem";
        format = "xfs";
        mountpoint = "/srv/media";
        mountOptions = noExec;
      };
    };
  };

  # Members can write to it without sudo, and new files keep the group.
  users.groups.media.members = [
    "captain"
    "riley"
  ];
  systemd.tmpfiles.rules = [ "d /srv/media 2775 root media -" ];

  boot.specialFileSystems."/dev/shm".options = [ "noexec" ];
}
