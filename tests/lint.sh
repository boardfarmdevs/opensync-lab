#!/usr/bin/env bash
#
# tests/lint.sh - every shell script the repository tracks (*.sh, and files whose first line
# runs bash or sh): bash -n / sh -n, and shellcheck against a baseline of the findings already
# there, so a new finding fails and a recorded one does not until it is fixed.
#
#   tests/lint.sh              check
#   tests/lint.sh --update     rewrite the baseline (tests/shellcheck-baseline) from today's findings
#
# The findings come from the pinned image koalaman/shellcheck-alpine:v0.10.0 (so CI and a
# workstation agree on them); SHELLCHECK=<binary> uses a local one instead.
# The baseline counts findings per file and code ("<count> <file> <code>"), not per line,
# so an edit elsewhere in a file does not shift it.

set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
BASELINE=tests/shellcheck-baseline
IMAGE=koalaman/shellcheck-alpine:v0.10.0

files=()
while IFS= read -r f; do
    [ -f "$f" ] || continue
    case "$f" in
        *.sh) files+=("$f") ;;
        *) head -n1 "$f" | grep -qE '^#!(/usr/bin/env |/bin/)(ba)?sh( |$)' && files+=("$f") ;;
    esac
done < <(git ls-files)

fail=0
for f in "${files[@]}"; do
    if head -n1 "$f" | grep -qE '^#!(/usr/bin/env |/bin/)sh( |$)'; then
        sh -n "$f" || { echo "sh -n: $f" >&2; fail=1; }
    else
        bash -n "$f" || { echo "bash -n: $f" >&2; fail=1; }
    fi
done
echo "syntax: ${#files[@]} scripts$([ "$fail" -eq 0 ] && echo ", ok")"

if [ -n "${SHELLCHECK:-}" ]; then
    sc() { "$SHELLCHECK" "$@"; }
else
    sc() { docker run --rm -v "$ROOT:/mnt:ro" -w /mnt "$IMAGE" shellcheck "$@"; }
fi
findings=$(sc -x -f gcc "${files[@]}" || true)
counts=$(printf '%s\n' "$findings" | sed -n 's/^\([^:]*\):[0-9]*:[0-9]*: [a-z]*: .*\[\(SC[0-9]*\)\]$/\1 \2/p' \
         | sort | uniq -c | awk '{print $1, $2, $3}')

if [ "${1:-}" = --update ]; then
    {
        echo "# shellcheck findings already in the repository, per file and code: a new one fails"
        echo "# tests/lint.sh. Fix them and shrink this file with tests/lint.sh --update."
        printf '%s\n' "$counts" | grep . || true
    } > "$BASELINE"
    echo "shellcheck: baseline rewritten ($(grep -vc '^#' "$BASELINE") file/code pairs)"
    exit "$fail"
fi

new=0 fewer=0
while read -r n file code; do
    [ -n "$file" ] || continue
    was=$(awk -v f="$file" -v c="$code" '$2 == f && $3 == c {print $1}' "$BASELINE" 2>/dev/null)
    if [ "$n" -gt "${was:-0}" ]; then
        echo "shellcheck: $file: $code $n times, baseline ${was:-0}:"
        printf '%s\n' "$findings" | grep -F "$file:" | grep -F "[$code]" | sed 's/^/  /'
        new=1
    fi
done <<< "$counts"
while read -r was file code; do
    case "$was" in ''|'#'*) continue ;; esac
    n=$(printf '%s\n' "$counts" | awk -v f="$file" -v c="$code" '$2 == f && $3 == c {print $1}')
    [ "${n:-0}" -lt "$was" ] && fewer=1
done < "$BASELINE"
if [ "$new" -eq 0 ]; then
    echo "shellcheck: no finding beyond the baseline$([ "$fewer" -eq 1 ] && echo " (fewer than recorded: tests/lint.sh --update)")"
else
    echo "shellcheck: new findings (above); fix them, or record them with tests/lint.sh --update"
    fail=1
fi
exit "$fail"
