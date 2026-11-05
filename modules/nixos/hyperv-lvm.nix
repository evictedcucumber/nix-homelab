# Disk layout for the managed Hyper-V VMs, whose disks are 64 GiB. Follows the separate
# file systems and mount options of the hardening benchmarks, plus /nix and the containers.
# About 7.5 GiB of the VG stays unassigned for growing a volume later.
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
            size = "16G";
            mountpoint = "/var/lib/nixos-containers";
          };
        };
  };

  boot.specialFileSystems."/dev/shm".options = [ "noexec" ];
}
