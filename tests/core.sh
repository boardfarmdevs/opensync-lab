#!/usr/bin/env bash
#
# tests/core.sh - the pod's core patches (pod/opensync/patches/core) apply to the pinned
# OpenSync core (pod/opensync/sources.lock), and the tests of what they change pass
# (pod/opensync/tests/*_test.c, built with the host's cc against the patched tree).
#
#   tests/core.sh
#
# The core comes from build-pod.sh's source cache when there is one (MVX_POD_SRC_CACHE,
# default ~/.cache/opensync-lab/pod-src), else one shallow fetch of the pinned commit.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
POD=$ROOT/pod
cache_dir=${MVX_POD_SRC_CACHE:-$HOME/.cache/opensync-lab/pod-src}

read -r _ url commit < <(awk '$1 == "core"' "$POD/opensync/sources.lock")
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cache=$cache_dir/$(basename "$url" .git).git
if [ -d "$cache" ] && git --git-dir="$cache" cat-file -e "$commit^{commit}" 2>/dev/null; then
    git clone -q --no-checkout "$cache" "$tmp/core"
else
    git init -q "$tmp/core"
    git -C "$tmp/core" fetch -q --depth 1 "$url" "$commit"
fi
git -C "$tmp/core" checkout -q --detach "$commit"

n=0
for p in "$POD/opensync/patches/core"/*.patch; do
    git -C "$tmp/core" apply "$p" || { echo "core.sh: does not apply: core/${p##*/}" >&2; exit 1; }
    n=$((n + 1))
done
echo "== core @ ${commit:0:12}: $n patches apply"

rc=0
for t in "$POD/opensync/tests"/*_test.c; do
    [ -e "$t" ] || continue
    name=$(basename "$t" .c)
    echo "== $name"
    if ! cc -std=gnu99 -Wall -Wextra -Werror -I "$tmp/core/src/cm2/src" -I "$tmp/core/src/lib/osw/src" \
        -o "$tmp/$name" "$t"; then
        echo "core.sh: $name does not build" >&2
        rc=1
        continue
    fi
    "$tmp/$name" || rc=1
done
exit "$rc"
