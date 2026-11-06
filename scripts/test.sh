#!/usr/bin/env bash
# Runs the named tests, or with no names only what the changes since $TEST_BASE can affect.
set -euo pipefail

tests=.#legacyPackages.x86_64-linux.tests

if [ $# -gt 0 ]; then
    exec nix build --no-link "${@/#/$tests.}"
fi

base=$(git merge-base "${TEST_BASE:-main}" HEAD)

untracked=$(git ls-files --others --exclude-standard)
if [ -n "$untracked" ]; then
    printf 'Not tested, because flakes only see files tracked by git:\n%s\n' "$untracked" >&2
fi

# Exclusions, not a list of paths, so a new directory gets tested by default.
if git diff --quiet "$base" -- . ':(exclude)*.md' ':(exclude)scripts' ':(exclude)justfile' \
    ':(exclude)LICENSE' ':(exclude).gitignore' ':(exclude).envrc' ':(exclude)lefthook.yml'; then
    echo "Nothing to test: no Nix changes since $base"
    exit 0
fi

# Test results are cached, so anything a change can't affect takes no time.
# Fast, so a broken assertion fails before the slow builds.
nix build --no-link .#checks.x86_64-linux.eval

# Building the hosts also runs the assertions the tests turn off. vm-dev is left out as its
# closure is large and nothing depends on it.
nix build --no-link --keep-going \
    .#nixosConfigurations.{cyclops,dcyclops,tcyclops}.config.system.build.toplevel
names=$(nix eval --raw "$tests" --apply \
    't: builtins.concatStringsSep " " (builtins.attrNames (removeAttrs t [ "boot" ]))')
read -ra nspawn <<<"$names"
nix build --no-link --keep-going "${nspawn[@]/#/$tests.}"

# What only a reboot can show. The rest of a host's config is activated without one.
boot_inputs() {
    nix eval --json "$1#nixosConfigurations.dcyclops.config" --apply 'c: {
        kernel = c.system.build.kernel.drvPath;
        initrd = c.system.build.initialRamdisk.drvPath;
        stage2 = c.system.build.bootStage2.drvPath;
        modules = c.system.modulesTree.drvPath;
        params = c.boot.kernelParams;
        kernelModules = c.boot.kernelModules;
        blacklist = c.boot.blacklistedKernelModules;
        sysctl = c.boot.kernel.sysctl;
        fileSystems = c.fileSystems;
    }'
}

root=$(git rev-parse --show-toplevel)
if ! before=$(boot_inputs "git+file://$root?rev=$base"); then
    echo "Could not evaluate dcyclops at $base, so testing boot" >&2
elif [ "$before" = "$(boot_inputs .)" ] && git diff --quiet "$base" -- tests/boot.nix; then
    echo "Skipped boot: nothing that affects it changed"
    exit 0
fi

echo "Testing boot, which is slow without KVM"
nix build --no-link "$tests.boot"
