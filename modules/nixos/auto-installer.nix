# Boots straight into an unattended install of `target`, which wipes the disk.
{ target }:
{ config, pkgs, ... }:
let
  inherit (target.config.system.build) destroyFormatMount toplevel;
  inherit (target.config.disko.devices.disk.main) device;
in
{
  virtualisation.hypervGuest.enable = true;
  nixpkgs.hostPlatform = "x86_64-linux";

  # Everything the install needs is on the ISO, so it works without a network.
  isoImage.storeContents = [
    destroyFormatMount
    toplevel
  ];

  systemd.services.auto-install = {
    description = "Unattended install of ${target.config.networking.hostName}";
    wantedBy = [ "multi-user.target" ];
    environment.HOME = "/root";
    path = [
      config.nix.package
      config.system.build.nixos-install
      pkgs.kmod
      pkgs.util-linux
    ];
    serviceConfig = {
      Type = "oneshot";
      StandardOutput = "journal+console";
      StandardError = "journal+console";
    };
    script = ''
      if [ "$(${pkgs.systemd}/bin/systemd-detect-virt)" != microsoft ]; then
        echo "Refusing to wipe the disk: not running in a Hyper-V VM." >&2
        exit 1
      fi

      # The disk can appear after this unit starts. If it never does, disko fails.
      for _ in {1..60}; do
        [ -b ${device} ] && break
        sleep 1
      done

      ${destroyFormatMount}/bin/disko-destroy-format-mount --yes-wipe-all-disks
      nixos-install --system ${toplevel} --no-root-password --no-channel-copy
      umount -R /mnt
      ${pkgs.systemd}/bin/systemctl reboot
    '';
  };
}
