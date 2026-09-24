#!/usr/bin/env bash
#
# build-docs.sh - the documentation site (docs/, served by GitHub Pages).
#
#   build-docs.sh viewer            copy local-noc's topology viewer into the site, unchanged
#   build-docs.sh reference         config, commands, scripts, workarounds -> docs/data/reference.json
#   build-docs.sh capture [--frames N] [--interval S]
#                                   record the running lab: topology frames, every node's raw
#                                   tables (secrets redacted), the check results
#   build-docs.sh all               viewer + reference (+ capture when the lab is reachable)
#   build-docs.sh serve [PORT]      preview the site on http://localhost:PORT/ (default 8000)
#
# The site is static (no build step to publish): GitHub Pages, "Deploy from a
# branch", main, /docs. The viewer on it is the same file local-noc serves; it
# replays the recording instead of polling a live local-noc.

set -euo pipefail
source "$(dirname "$(readlink -f "$0")")/lib/common.sh"
source "$MVX_ROOT/lib/vm.sh"

SITE=$MVX_ROOT/docs

noc_url() {
    local listen
    listen=$(lxc config device get "$MVX_VM" noc-ui listen 2>/dev/null) || return 1
    echo "http://${listen#tcp:}"
}

cmd_viewer() {
    install -D -m 0644 "$MVX_ROOT/local-noc/webui/index.html" "$SITE/topology/index.html"
    log "viewer: local-noc/webui/index.html -> docs/topology/"
}

cmd_reference() {
    python3 "$MVX_ROOT/lib/docs.py" reference "$MVX_ROOT" "$SITE/data/reference.json"
}

cmd_capture() {
    local frames=12 interval=5 url
    while [ $# -gt 0 ]; do
        case "$1" in
            --frames) frames=$2; shift 2 ;;
            --interval) interval=$2; shift 2 ;;
            *) die "capture: unknown option $1" ;;
        esac
    done
    url=$(noc_url) || die "no local-noc web UI on $MVX_VM (setup-vm.sh provision)"
    curl -fs -o /dev/null "$url/api/topology" || die "local-noc not answering at $url"
    log "capture: $url, $frames frames every ${interval}s"
    lxc exec "$MVX_VM" -- sh -c 'for f in /var/lib/opensync-lab/*.status; do
            n=$(basename "$f" .status); while IFS= read -r l; do printf "%s\t%s\n" "$n" "$l"; done < "$f"; done' |
        python3 "$MVX_ROOT/lib/docs.py" capture "$url" "$SITE/topology" "$frames" "$interval" "$SITE/data/checks.json"
}

cmd_serve() {
    local port=${1:-8000}
    log "serve: http://localhost:$port/  (Ctrl-C to stop)"
    exec python3 -m http.server --directory "$SITE" --bind 127.0.0.1 "$port"
}

usage() { sed -n '3,14p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

cmd=${1:-}; [ $# -gt 0 ] && shift
case "$cmd" in
    viewer)    cmd_viewer ;;
    reference) cmd_reference ;;
    capture)   cmd_capture "$@" ;;
    all)       cmd_viewer; cmd_reference
               if noc_url >/dev/null 2>&1; then cmd_capture "$@"; else warn "lab not reachable: keeping the recorded topology"; fi ;;
    serve)     cmd_serve "$@" ;;
    *)         usage ;;
esac
