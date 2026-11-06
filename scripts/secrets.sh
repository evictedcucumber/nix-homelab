#!/usr/bin/env bash
# secrets.sh init <host>
# secrets.sh check <host> <target>
# secrets.sh rekey <host> <target>
# Manages secrets/<host>.yaml. A host decrypts it with an age key derived from its SSH host
# key, which the host's public key is fetched for over the authenticated SSH connection.
set -euo pipefail

cd "$(dirname "$0")/.."

user=${DEPLOY_USER:-captain}
names=(grafana-admin-password grafana-secret-key pihole-web-password)

usage() {
    echo "usage: $0 init <host> | $0 <check|rekey> <host> <target>" >&2
    exit 2
}

die() {
    echo "$*" >&2
    exit 1
}

[ $# -ge 2 ] || usage
action=$1
host=$2
[[ $host =~ ^[a-z][a-z0-9-]*$ ]] || die "invalid host name: $host"
file=secrets/$host.yaml

need() {
    command -v "$1" > /dev/null || die "$1 is missing: enter the dev shell with 'nix develop'"
}

# Sets pub to the host's SSH public key and key to its age recipient.
fetch_host_key() {
    local target=$1
    [[ $target == *@* ]] || target=$user@$target
    [[ $target =~ ^[A-Za-z0-9._-]+@[A-Za-z0-9._:-]+$ ]] || die "invalid target: $target"
    need ssh-to-age
    # NIX_SSHOPTS is a word list, so it is left unquoted.
    # shellcheck disable=SC2086
    pub=$(ssh $NIX_SSHOPTS -- "$target" cat /etc/ssh/ssh_host_ed25519_key.pub) ||
        die "could not read the SSH host key of $target"
    key=$(printf '%s\n' "$pub" | ssh-to-age) || die "could not convert the SSH host key of $target"
    [[ $key =~ ^age1[a-z0-9]{58}$ ]] || die "unexpected age recipient from $target"
}

random() {
    head -c 32 /dev/urandom | base64 -w0 | tr -d '=' | tr '+/' '-_'
}

case "$action" in
    init)
        [ $# -eq 2 ] || usage
        need sops
        [ ! -e "$file" ] || die "$file exists: edit it with 'sops $file'"
        grep -q "path_regex: ^secrets/$host\\\\.yaml\\$" .sops.yaml || die "no rule for $file in .sops.yaml"
        tmp=$(mktemp "secrets/.$host.XXXXXX")
        trap 'rm -f "$tmp"' EXIT
        # The plaintext only exists in variables, and as a pipe into sops.
        for name in "${names[@]}"; do
            printf '%s: "%s"\n' "$name" "$(random)"
        done | sops encrypt --filename-override "$file" --input-type yaml --output-type yaml /dev/stdin > "$tmp"
        mv -n "$tmp" "$file"
        [ ! -e "$tmp" ] || die "$file appeared meanwhile, so it was left alone"
        echo "Created $file for the admin key only. Once $host is installed, run 'just secrets-rekey $host'."
        ;;
    check)
        [ $# -eq 3 ] || usage
        [ -f "$file" ] || die "no $file: run 'just secrets-init $host'"
        fetch_host_key "$3"
        grep -Fq "recipient: $key" "$file" ||
            die "$file isn't encrypted for $host's current SSH host key ($key): run 'just secrets-rekey $host'"
        ;;
    rekey)
        [ $# -eq 3 ] || usage
        [ -f "$file" ] || die "no $file: run 'just secrets-init $host'"
        need sops
        need yq
        need ssh-keygen
        fetch_host_key "$3"
        echo "Fetched SSH host key of $3:" >&2
        printf '%s\n' "$pub" | ssh-keygen -lf /dev/stdin >&2
        echo "Compare it with 'ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub' on the host's console." >&2
        read -r -p "Does it match? [y/N] " answer || die "no answer: .sops.yaml is unchanged"
        [[ ${answer,,} == y || ${answer,,} == yes ]] || die "not confirmed: .sops.yaml is unchanged"
        backup=$(mktemp)
        done=
        restore() {
            [ -n "$done" ] || cp "$backup" .sops.yaml
            rm -f "$backup"
        }
        trap restore EXIT
        trap 'exit 130' INT TERM HUP
        cp .sops.yaml "$backup"
        # The recipient commented "host" is replaced in place, or added last if there is none.
        # shellcheck disable=SC2016
        HOST=$host KEY=$key yq -i '
            (.creation_rules[] | select(.path_regex == "^secrets/" + strenv(HOST) + "\\.yaml$") | .key_groups[0].age) |= (
                (strenv(KEY) | . line_comment = "host") as $new |
                (map(select(line_comment == "host")) | length) as $n |
                if $n > 0 then map(select(line_comment == "host") = $new) else . + [$new] end)' .sops.yaml
        grep -Fq "$key" .sops.yaml || die "could not rekey $file: .sops.yaml is unchanged"
        sops updatekeys -y "$file" || die "could not rekey $file: .sops.yaml is unchanged"
        done=1
        echo "Encrypted $file for $host's key $key. Deploy it with 'just deploy $host'."
        ;;
    *) usage ;;
esac
