# shellcheck shell=bash
# Shared helpers for the opensync-lab scripts. Source, don't execute.

MVX_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export MVX_ROOT

# config: environment > config/local.conf (untracked, written by the scripts)
# > config/mvx.conf defaults. Both files only assign unset variables (:=), so
# local.conf must be read first for its values to win over the defaults.
[ -f "$MVX_ROOT/config/local.conf" ] && source "$MVX_ROOT/config/local.conf"
# shellcheck source=../config/mvx.conf
source "$MVX_ROOT/config/mvx.conf"

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

# Per-product build facts. Sets PROD_MACHINE, PROD_META, PROD_SUBDIR.
product_info() {
    case "$1" in
        mv3)     PROD_MACHINE=exm-qemux86-mv3;     PROD_META=meta-lxd-mv3;     PROD_SUBDIR= ;;
        mv37)    PROD_MACHINE=exm-qemux86-mv37;    PROD_META=meta-lxd-mv37;    PROD_SUBDIR= ;;
        mv2plus) PROD_MACHINE=exm-qemux86-mv2plus; PROD_META=meta-lxd-mv2plus; PROD_SUBDIR=brcm-openbfc-rdkm-scom ;;
        mv27)    PROD_MACHINE=exm-qemux86-mv27;    PROD_META=meta-lxd-mv27;    PROD_SUBDIR=brcm-openbfc-rdkm ;;
        *) die "unknown product: $1" ;;
    esac
}

# Record a setting in config/local.conf (untracked), replacing an older value.
persist_local() {
    local key=$1 val=$2 f=$MVX_ROOT/config/local.conf
    touch "$f"
    sed -i "/^: \"\${$key:=/d" "$f"
    printf ': "${%s:=%s}"\n' "$key" "$val" >> "$f"
}
