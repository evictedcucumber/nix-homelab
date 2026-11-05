# Log limits for hosts and containers. The minimal profile turns logrotate off, which also
# leaves the rules nixpkgs adds for wtmp, btmp and Pi-hole unused.
{ lib, ... }:
{
  services.logrotate.enable = true;

  services.journald.settings.Journal = {
    SystemMaxUse = lib.mkDefault "2G";
    # Retention only removes archived files, so archive sooner than the default month.
    MaxFileSec = "1week";
    MaxRetentionSec = "1month";
  };
}
