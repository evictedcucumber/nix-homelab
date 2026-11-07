# What every managed host gets. The Hyper-V, installer and per-container modules stay out.
{
  imports = [
    ./common.nix
    ./dns.nix
    ./firewall.nix
    ./hardening.nix
    ./home-manager.nix
    ./log-retention.nix
    ./minimal.nix
    ./secrets.nix
  ];
}
