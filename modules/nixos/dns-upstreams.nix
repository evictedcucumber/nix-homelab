# In priority order. Shared by dns.nix and the firewall's allowlist.
[
  {
    address = "1.1.1.1";
    name = "one.one.one.one";
  }
  {
    address = "1.0.0.1";
    name = "one.one.one.one";
  }
  {
    address = "9.9.9.9";
    name = "dns.quad9.net";
  }
  {
    address = "149.112.112.112";
    name = "dns.quad9.net";
  }
]
