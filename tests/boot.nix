# Boots a real host's kernel, initrd and stage 2, but not its bootloader, which QEMU skips.
{
  name = "boot";

  # The host's modules set nixpkgs options.
  node.pkgsReadOnly = false;

  nodes.machine = {
    # Boot is all this checks, and they're slow without KVM.
    containers = {
      grafana.autoStart = false;
      pihole.autoStart = false;
    };
    virtualisation = {
      memorySize = 2048;
      cores = 4;
    };
  };

  testScript = ''
    machine.wait_for_unit("multi-user.target")
    machine.succeed("systemctl is-active sshd.service nftables.service")
  '';
}
