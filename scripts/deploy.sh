#!/usr/bin/env bash
# deploy.sh address <host>
# deploy.sh <switch|test> <host> [target]
# Builds a host here, signs and copies the closure, then activates it with one sudo prompt.
set -euo pipefail

user=${DEPLOY_USER:-captain}
key=${NIX_HOMELAB_SIGNING_KEY:-$HOME/.config/nix-homelab/signing.key}

default_address() {
    case "$1" in
        dcyclops) echo 172.16.1.2 ;;
        tcyclops) echo 172.16.0.2 ;;
        *)
            echo "pass a target: just <recipe> $1 <address>" >&2
            return 1
            ;;
    esac
}

usage() {
    echo "usage: $0 address <host> | $0 <switch|test> <host> [target]" >&2
    exit 2
}

[ $# -ge 2 ] || usage
action=$1
host=$2
[[ $host =~ ^[a-z][a-z0-9-]*$ ]] || { echo "invalid host name: $host" >&2; exit 2; }

if [ "$action" = address ]; then
    [ $# -eq 2 ] || usage
    default_address "$host"
    exit
fi

case "$action" in
    switch | test) ;;
    *) usage ;;
esac
[ $# -le 3 ] || usage

target=${3:-$(default_address "$host")}
[[ $target == *@* ]] || target=$user@$target
[[ $target =~ ^[A-Za-z0-9._-]+@[A-Za-z0-9._:-]+$ ]] || { echo "invalid target: $target" >&2; exit 2; }

[ -f "$key" ] || { echo "no signing key at $key: run 'just signing-key'" >&2; exit 1; }

# NIX_SSHOPTS is a word list, so it is left unquoted.
# shellcheck disable=SC2086,SC2029
ssh $NIX_SSHOPTS "$target" true

# The host can only decrypt its secrets if they're encrypted for its current SSH host key.
"$(dirname "$0")/secrets.sh" check "$host" "$target"

out=$(nix build --no-link --print-out-paths ".#nixosConfigurations.$host.config.system.build.toplevel")
nix store sign --recursive --key-file "$key" "$out"
nix copy --to "ssh-ng://$target" "$out"

# shellcheck disable=SC2086,SC2029
ssh $NIX_SSHOPTS "$target" nix store diff-closures /run/current-system "$out" || true

exec nixos-rebuild "$action" --store-path "$out" --target-host "$target" \
    --elevate sudo --ask-elevate-password
