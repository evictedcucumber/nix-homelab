#!/usr/bin/env bash
# check-secrets.sh <path>...
# Pre-commit check on the staged content (not the working tree) of the given paths: a
# secrets file must be sops-encrypted, and no age private key may be committed but the tests'.
set -uo pipefail

key_pattern='AGE-SECRET''-KEY-'
allowed=tests/secrets/age-key.txt
status=0

fail() {
    echo "$1" >&2
    status=1
}

for path in "$@"; do
    content=$(git show ":$path" 2> /dev/null) || continue

    if [[ $path =~ (^|/)secrets/[^/]+\.yaml$ ]]; then
        if ! grep -q '^sops:' <<< "$content"; then
            fail "$path has no top-level 'sops:' key, so it isn't sops-encrypted"
        elif ! awk '
            /^sops:/ { exit }
            /^[[:space:]]*(#|$)/ { next }
            /:[[:space:]]*$/ { next }
            { v = $0; sub(/^[^:]*:[[:space:]]*/, "", v); sub(/^["\047]/, "", v); if (v !~ /^ENC\[/) bad = 1 }
            END { exit bad }' <<< "$content"; then
            fail "$path has a value that isn't ENC[...]: it isn't fully sops-encrypted"
        fi
    fi

    if [ "$path" != "$allowed" ] && grep -aq -- "$key_pattern" <<< "$content"; then
        fail "$path contains an age private key"
    fi
done

exit "$status"
