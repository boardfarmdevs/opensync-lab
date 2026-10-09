# shellcheck shell=bash
# tests/guest/lib.sh - the guest tests' harness (sourced by run.sh): stub commands that record
# their calls and answer from a behaviour script per test, and assertions.

STUB_DIR=$(mktemp -d)
STUB_LOG=$STUB_DIR/calls.log
export STUB_DIR STUB_LOG
mkdir -p "$STUB_DIR/bin" "$STUB_DIR/behave"
PATH=$STUB_DIR/bin:$PATH
STUBS="docker lxc systemctl curl"

# a stub: logs "<name> <args>" and runs behave/<name> with the same arguments, if there is
# one (its exit status is the stub's); otherwise succeeds silently
for s in $STUBS; do
    cat > "$STUB_DIR/bin/$s" <<'EOF'
#!/usr/bin/env bash
n=${0##*/}
printf '%s\n' "$n $*" >> "$STUB_LOG"
[ -f "$STUB_DIR/behave/$n" ] && exec bash "$STUB_DIR/behave/$n" "$@"
exit 0
EOF
    chmod +x "$STUB_DIR/bin/$s"
done

# behave <stub>: its behaviour for the next test, from stdin (a bash script with "$@")
behave() { cat > "$STUB_DIR/behave/$1"; }

reset() {
    rm -f "$STUB_DIR"/behave/* "$STUB_LOG"
    : > "$STUB_LOG"
    rm -rf /var/lib/opensync-lab /etc/default/local-noc /usr/local/sbin/local-noc-net \
        /etc/systemd/system/local-noc-net.service
}

TESTS=0 FAILS=0 CURRENT=
test_case() { CURRENT=$1; TESTS=$((TESTS + 1)); reset; }
ok()   { printf '  ok    %s: %s\n' "$CURRENT" "$1"; }
bad()  { printf '  FAIL  %s: %s\n' "$CURRENT" "$1"; FAILS=$((FAILS + 1)); }

assert_eq()      { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3: got '$1', want '$2'"; fi; }
assert_match()   { if printf '%s\n' "$1" | grep -qE -- "$2"; then ok "$3"; else bad "$3: '$2' not in: $1"; fi; }
assert_no_match() { if printf '%s\n' "$1" | grep -qE -- "$2"; then bad "$3: '$2' in: $1"; else ok "$3"; fi; }
assert_called()  { assert_match "$(cat "$STUB_LOG")" "$1" "called: $1"; }
assert_file()    {   # <file> <regex> [mode]
    if [ ! -f "$1" ]; then bad "no file $1"; return; fi
    assert_match "$(cat "$1")" "$2" "$1 has $2"
    [ -z "${3:-}" ] || assert_eq "$(stat -c %a "$1")" "$3" "$1 mode"
}
