# Shared by the Generation 2 Hyper-V VMs. Their disk layout and hardware are
# fixed, so they need no generated hardware config.
{
  virtualisation.hypervGuest.enable = true;
  nixpkgs.hostPlatform = "x86_64-linux";

  # kvm-amd gives nested VMs /dev/kvm on this Ryzen host. uio_hv_generic is the
  # driver behind the Guest Service Interface, which hv-fcopy uses.
  boot.kernelModules = [
    "kvm-amd"
    "uio_hv_generic"
  ];

  # nixpkgs prefixes this condition with /dev/vmbus/, so hv-fcopy never starts.
  systemd.services.hv-fcopy.unitConfig.ConditionPathExists = [
    ""
    "/sys/bus/vmbus/devices/eb765408-105f-49b6-b4aa-c123b64d17d4/uio"
  ];

  boot.loader = {
    systemd-boot.enable = true;
    # Puts the installed system ahead of the DVD in the firmware's boot order.
    efi.canTouchEfiVariables = true;
  };

  # Internal switches have no DHCP, so each host sets its own address and gateway.
  networking = {
    domain = "nix.homelab.zezura.cc";
    useDHCP = false;
    usePredictableInterfaceNames = false;
    nameservers = [ "1.1.1.1" ];
  };

  disko.devices.disk.main = {
    device = "/dev/sda";
    type = "disk";
    content = {
      type = "gpt";
      partitions = {
        ESP = {
          type = "EF00";
          size = "512M";
          content = {
            type = "filesystem";
            format = "vfat";
            mountpoint = "/boot";
            mountOptions = [ "umask=0077" ];
          };
        };
        root = {
          size = "100%";
          content = {
            type = "filesystem";
            format = "ext4";
            mountpoint = "/";
          };
        };
      };
    };
  };

  # The auto-install ISO installs from this flake's nixpkgs.
  system.stateVersion = "26.11";
}
