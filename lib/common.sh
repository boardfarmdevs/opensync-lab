# shellcheck shell=bash
# Shared helpers for the opensync-lab scripts. Source, don't execute.

MVX_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export MVX_ROOT

# config: environment > config/local.conf (untracked, written by the scripts)
# > config/mvx.conf defaults > private.conf. The files only assign unset or empty
# variables (:=), so local.conf must be read first for its values to win over the
# defaults; private.conf fills what the defaults leave empty (pins/README.md).
# shellcheck source=/dev/null  # local.conf: untracked, machine-local
[ -f "$MVX_ROOT/config/local.conf" ] && source "$MVX_ROOT/config/local.conf"
# shellcheck source-path=SCRIPTDIR source=../config/mvx.conf
source "$MVX_ROOT/config/mvx.conf"
if [ -r "$OPENSYNC_LAB_PRIVATE/private.conf" ]; then
    # shellcheck source=/dev/null # private: not in this repository
    source "$OPENSYNC_LAB_PRIVATE/private.conf"
fi

log()  { printf '\033[1;34m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
warn() { printf '\033[1;33m[%s] WARN\033[0m %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
die()  { printf '\033[1;31m[%s] FATAL\033[0m %s\n' "$(date +%H:%M:%S)" "$*" >&2; exit 1; }

require_cmd() {
    local c
    for c in "$@"; do
        command -v "$c" >/dev/null 2>&1 || die "required command missing: $c"
    done
}

# Tee all further output of the calling script into logs/<name>-<ts>.log.
start_log() {
    local name=$1
    install -d "$MVX_ROOT/logs"
    MVX_LOG="$MVX_ROOT/logs/${name}-$(date +%Y%m%d-%H%M%S).log"
    exec > >(tee -a "$MVX_LOG") 2>&1
    log "logging to $MVX_LOG"
}

# wait_for <timeout-seconds> <interval> <description> <command...>
wait_for() {
    local timeout=$1 interval=$2 what=$3
    shift 3
    local deadline=$((SECONDS + timeout))
    while [ "$SECONDS" -lt "$deadline" ]; do
        if "$@" >/dev/null 2>&1; then
            return 0
        fi
        sleep "$interval"
    done
    warn "timed out after ${timeout}s waiting for: $what"
    return 1
}

# A product's build subdirectory, from OPENSYNC_LAB_SUBDIRS (private.conf): empty if none.
product_subdir() {
    local kv
    # shellcheck disable=SC2086  # split "<product>=<subdir> ..." on spaces
    for kv in $OPENSYNC_LAB_SUBDIRS; do
        [ "${kv%%=*}" = "$1" ] && { echo "${kv#*=}"; return 0; }
    done
    return 0
}

# Per-product build facts. Sets PROD_MACHINE, PROD_META, PROD_SUBDIR.
# shellcheck disable=SC2034  # used by the scripts that source this file
product_info() {
    case "$1" in
        mv3)     PROD_MACHINE=exm-qemux86-mv3;     PROD_META=meta-lxd-mv3;     PROD_SUBDIR= ;;
        mv37)    PROD_MACHINE=exm-qemux86-mv37;    PROD_META=meta-lxd-mv37;    PROD_SUBDIR= ;;
        mv2plus) PROD_MACHINE=exm-qemux86-mv2plus; PROD_META=meta-lxd-mv2plus; PROD_SUBDIR=$(product_subdir "$1") ;;
        mv27)    PROD_MACHINE=exm-qemux86-mv27;    PROD_META=meta-lxd-mv27;    PROD_SUBDIR=$(product_subdir "$1") ;;
        *) die "unknown product: $1" ;;
    esac
}

# Record a setting in config/local.conf (untracked), replacing an older value.
persist_local() {
    local key=$1 val=$2 f=$MVX_ROOT/config/local.conf
    touch "$f"
    sed -i "/^: \"\${$key:=/d" "$f"
    # shellcheck disable=SC2016  # a literal ${KEY:=value} line for local.conf
    printf ': "${%s:=%s}"\n' "$key" "$val" >> "$f"
}
