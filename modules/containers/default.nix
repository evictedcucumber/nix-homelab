# Every container the hosts run. Each sets its lan.hostNumber, and a host's lan.prefix makes
# it an address.
{
  imports = [
    ./grafana
    ./ntfy
    ./pihole
  ];
}
