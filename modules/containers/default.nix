# Every container the hosts run. A host picks a container's LAN address in its own config.
{
  imports = [
    ./ntfy
    ./pihole
  ];
}
