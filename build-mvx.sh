#!/usr/bin/env bash
#
# build-mvx.sh - build an mvx LXD container image from a fresh checkout,
# pinned to a known-good reference build, fully offline.
#
#   build-mvx.sh pin    [--from DIR]           capture pins + pin store from a reference build
#   build-mvx.sh build  [--dir DIR] [--resume]  fresh repo init + pinned bitbake
#   build-mvx.sh all                            pin (if missing) + build
#   build-mvx.sh status [DIR]                   show build dir, markers, artifact
#
# Pinned: every manifest project at the reference's HEAD sha; the meta-lxd,
# meta-lxd-<product> and meta-python2 clones at the reference's commits; and
# every SRCREV bitbake resolved in the reference (from buildhistory), forced
# with SRCREV:pn-<recipe>. Most RDK recipes are SRCREV ?= ${AUTOREV}.
#
# Offline: the checkout reads only local git. The pin step builds a "pin store"
# ($MVX_PIN_STORE): one bare repo per project and layer, whose branch points
# at the pinned commit. Each repo borrows objects from the repo_reference
# mirror through alternates and adds only the commits the mirror lacks (the
# mirror is older than the reference build), so the shared mirror is never
# modified. The pinned manifest is committed to the store's manifests.git on
# branch mvx/<pins>. At build time every remote URL is redirected into the
# store with process-scoped git config (GIT_CONFIG_COUNT). Nothing is written
# to ~/.gitconfig.
# bitbake itself needs no redirect: the mng distro builds the RDK components
# from the checkout's own src/ (file://), and the other bitbucket SRC_URIs
# (hal-wifi-hwsim, rbus-*, opensync-service-provider-local) are pinned and
# already cached in $MVX_DL_DIR/git2.
#
# Settings: config/mvx.conf, all overridable from the environment.

set -euo pipefail
source "$(dirname "$(readlink -f "$0")")/lib/common.sh"

product_info "$MVX_PRODUCT"
MANIFEST_URL=ssh://git@bitbucket.upc.biz:7999/rdkb/manifests.git
PINS_DIR="$MVX_ROOT/pins/$MVX_PINS"
: "${MVX_PIN_STORE:=$HOME/yocto/repo_reference/mvx-pins/$MVX_PINS}"
PIN_BRANCH="mvx/$MVX_PINS"

subdir_of() { echo "$1${PROD_SUBDIR:+/$PROD_SUBDIR}"; }  # dir holding build-<machine>/

# --------------------------------------------------------------------------- pin

# store_repo <bare-repo> <source-worktree> <sha> <branch>
# Create/refresh a bare repo that borrows the mirror's objects and holds
# <branch> = <sha>. Only objects the mirror lacks are copied (by push).
store_repo() {
    local bare=$1 src=$2 sha=$3 branch=$4 mirror=${5:-}
    if [ ! -d "$bare" ]; then
        git init -q --bare "$bare"
        [ -n "$mirror" ] && [ -d "$mirror/objects" ] \
            && echo "$mirror/objects" > "$bare/objects/info/alternates"
    fi
    git -C "$src" push -q --force "$bare" "$sha:refs/heads/$branch"
    [ "$(git --git-dir="$bare" rev-parse "refs/heads/$branch")" = "$sha" ] \
        || die "store: $bare $branch != $sha"
}

cmd_pin() {
    local ref=$MVX_REF_BUILD
    while [ $# -gt 0 ]; do
        case "$1" in
            --from) ref=$2; shift 2 ;;
            *) die "pin: unknown option $1" ;;
        esac
    done
    local root bdir bh
    [ -d "$ref/.repo" ] || die "not a repo checkout: $ref"
    root=$(subdir_of "$ref")
    bdir="$root/build-$PROD_MACHINE"
    bh="$bdir/buildhistory"
    [ -d "$bh" ] || die "reference has no buildhistory: $bh"
    [ -d "$MVX_REPO_REF" ] || die "repo reference mirror missing: $MVX_REPO_REF"
    install -d "$PINS_DIR" "$MVX_PIN_STORE/layers"
    log "pin: $ref -> $PINS_DIR (store $MVX_PIN_STORE)"

    # 1. revision-locked manifest
    python3 "$MVX_ROOT/lib/pin-manifest.py" "$ref" "$PINS_DIR/manifest.xml"

    # 2. project repos in the store; count what the mirror was missing
    local name path sha branch missing=0 total=0
    while read -r name path sha branch; do
        total=$((total + 1))
        git --git-dir="$MVX_REPO_REF/$name.git" cat-file -e "$sha^{commit}" 2>/dev/null \
            || { missing=$((missing + 1)); log "pin:   $name: ${sha:0:12} not in mirror, stored"; }
        store_repo "$MVX_PIN_STORE/$name.git" "$ref/$path" "$sha" "${branch#refs/heads/}" "$MVX_REPO_REF/$name.git"
    done < "$PINS_DIR/manifest.xml.projects"
    log "pin: $total projects in the store, $missing carried commits the mirror lacks"

    # 3. manifests repo: the manifest revision the reference used + mvx-pinned.xml
    local mref=$ref/.repo/manifests tmp
    tmp=$(mktemp -d)
    git clone -q --no-checkout "$ref/.repo/manifests.git" "$tmp/m"
    git -C "$tmp/m" checkout -q --detach "$(git -C "$mref" rev-parse HEAD)"
    cp "$PINS_DIR/manifest.xml" "$tmp/m/mvx-pinned.xml"
    git -C "$tmp/m" add mvx-pinned.xml
    git -C "$tmp/m" -c user.name=mvx-opensync -c user.email=mvx-opensync@localhost \
        commit -q -m "mvx-pinned.xml: $MVX_PINS (from $ref)"
    store_repo "$MVX_PIN_STORE/manifests.git" "$tmp/m" "$(git -C "$tmp/m" rev-parse HEAD)" "$PIN_BRANCH" "$MVX_REPO_REF/manifests.git"
    rm -rf "$tmp"

    # 4. layers cloned outside repo
    : > "$PINS_DIR/layers.lock"
    local layer url
    for layer in meta-lxd "$PROD_META" meta-python2; do
        [ -d "$root/$layer/.git" ] || die "reference is missing layer $layer"
        [ -z "$(git -C "$root/$layer" status --porcelain --untracked-files=no)" ] \
            || die "reference layer $layer has local modifications"
        sha=$(git -C "$root/$layer" rev-parse HEAD)
        branch=$(git -C "$root/$layer" rev-parse --abbrev-ref HEAD)
        url=$(git -C "$root/$layer" remote get-url origin)
        store_repo "$MVX_PIN_STORE/layers/$layer.git" "$root/$layer" "$sha" "$branch"
        printf '%s %s %s %s\n' "$layer" "$branch" "$sha" "$url" >> "$PINS_DIR/layers.lock"
    done

    # 5. every SRCREV the reference resolved (AUTOREV or not)
    {
        echo "# SRCREVs resolved by the reference build $ref"
        echo "# (openembedded-core/scripts/buildhistory-collect-srcrevs -a)"
        python3 "$ref/openembedded-core/scripts/buildhistory-collect-srcrevs" -a -p "$bh"
    } > "$PINS_DIR/srcrev.inc"

    # 6. what the reference produced, for the reproducibility check
    local img_bh image
    img_bh=$(find "$bh/images" -maxdepth 3 -type d -path '*/glibc/ofw' | head -1)
    [ -n "$img_bh" ] || die "no image buildhistory under $bh/images"
    cp "$img_bh/installed-package-names.txt" "$PINS_DIR/"
    cp "$img_bh/installed-package-sizes.txt" "$PINS_DIR/"
    image=$(readlink -f "$bdir/tmp/deploy/images/$PROD_MACHINE/ofw-$PROD_MACHINE.tar.bz2")
    cat > "$PINS_DIR/reference.txt" <<EOF
reference_build=$ref
manifest=$(basename "$(readlink -f "$ref/.repo/manifest.xml")") @ $(git -C "$mref" rev-parse --short HEAD)
machine=$PROD_MACHINE
image=$(basename "$image")
image_sha256=$(sha256sum "$image" | awk '{print $1}')
buildhistory_head=$(git -C "$bh" log -1 --format='%h %s' 2>/dev/null)
pin_store=$MVX_PIN_STORE (branch $PIN_BRANCH), $(du -sh "$MVX_PIN_STORE" | cut -f1)
projects=$total missing_from_mirror=$missing
pinned_at=$(date -Is) by $(id -un)@$(hostname)
EOF
    log "pin: done"
    sed 's/^/    /' "$PINS_DIR/reference.txt" "$PINS_DIR/layers.lock"
}

# ------------------------------------------------------------------ redirects

# Process-scoped url.<new>.insteadOf <old> rules (git >= 2.31).
setup_redirects() {
    local -a pairs=()
    local base layer branch sha url
    while read -r base; do
        pairs+=("file://$MVX_PIN_STORE/|${base%/}/")
    done < <( { grep -oE 'fetch="[^"]+"' "$PINS_DIR/manifest.xml" | sed 's/fetch="//;s/"$//'; \
               echo "${MANIFEST_URL%/*}"; } | sort -u)
    while read -r layer branch sha url; do
        pairs+=("$MVX_PIN_STORE/layers/$layer.git|$url")
    done < "$PINS_DIR/layers.lock"

    local i=0 p
    for p in "${pairs[@]}"; do
        export "GIT_CONFIG_KEY_$i=url.${p%%|*}.insteadOf" "GIT_CONFIG_VALUE_$i=${p#*|}"
        i=$((i + 1))
    done
    export GIT_CONFIG_COUNT=$i
    # repo pre-opens an ssh ControlMaster to every ssh:// remote before git
    # applies insteadOf; with GIT_SSH set it skips that (harmless, but noisy).
    export GIT_SSH=${GIT_SSH:-ssh}
    log "offline: $i process-scoped git redirects into $MVX_PIN_STORE"
    for p in "${pairs[@]}"; do printf '    %-62s -> %s\n' "${p#*|}" "${p%%|*}"; done
}

# The repo tool itself: gerrit if reachable, else the newest local clone.
repo_tool_args() {
    if timeout 15 git ls-remote https://gerrit.googlesource.com/git-repo refs/heads/stable >/dev/null 2>&1; then
        echo "--repo-rev=stable"
        return
    fi
    local d best="" best_t=0 t
    for d in "$HOME"/yocto/*/.repo/repo; do
        [ -d "$d/.git" ] || continue
        t=$(git -C "$d" log -1 --format=%ct 2>/dev/null || echo 0)
        [ "$t" -gt "$best_t" ] && { best=$d; best_t=$t; }
    done
    [ -n "$best" ] || die "gerrit unreachable and no local repo tool clone found"
    warn "gerrit unreachable, using local repo tool $best"
    echo "--repo-url=$best --repo-rev=$(git -C "$best" rev-parse --abbrev-ref HEAD)"
}

# ---------------------------------------------------------------------- build

marker() { echo "$BUILD_DIR/.mvx-$1"; }
artifact() {
    echo "$(subdir_of "$BUILD_DIR")/build-$PROD_MACHINE/tmp/deploy/images/$PROD_MACHINE/ofw-$PROD_MACHINE.tar.bz2"
}

step_checkout() {
    if [ -f "$(marker checkout)" ]; then log "checkout: done (marker)"; return; fi
    log "checkout: repo init ($PIN_BRANCH / mvx-pinned.xml) + sync in $BUILD_DIR"
    cd "$BUILD_DIR"
    # shellcheck disable=SC2046
    repo init $(repo_tool_args) --no-repo-verify --reference="$MVX_REPO_REF" \
        -u "$MANIFEST_URL" -b "$PIN_BRANCH" -m mvx-pinned.xml </dev/null
    repo sync -j8 --current-branch --no-tags --fail-fast </dev/null

    log "checkout: verifying every project HEAD against the pin"
    local bad
    bad=$(repo forall -c 'h=$(git rev-parse HEAD); [ "$h" = "$REPO_RREV" ] || echo "$REPO_PATH $h != $REPO_RREV"')
    [ -z "$bad" ] || { printf '%s\n' "$bad" >&2; die "projects not at their pinned revision"; }
    log "checkout: $(repo list | wc -l) projects at their pinned revisions"
    touch "$(marker checkout)"
}

step_layers() {
    if [ -f "$(marker layers)" ]; then log "layers: done (marker)"; return; fi
    local layer branch sha url
    cd "$(subdir_of "$BUILD_DIR")"
    while read -r layer branch sha url; do
        log "layers: $layer $branch @ ${sha:0:12}"
        [ -d "$layer" ] || git clone -q -b "$branch" "$url" "$layer"
        git -C "$layer" checkout -q "$sha"
        [ "$(git -C "$layer" rev-parse HEAD)" = "$sha" ] || die "$layer not at $sha"
        # point origin back at the real upstream, not the store
        git -C "$layer" remote set-url origin "$url"
    done < "$PINS_DIR/layers.lock"
    touch "$(marker layers)"
}

# setup-environment must be sourced by a shell without set -eu; everything
# bitbake-related runs in this child.
in_build_env() {
    env -u GIT_CONFIG_COUNT MACHINE="$PROD_MACHINE" bash -c '
        cd "$1" || exit 1
        meta=$2 cmd=$3
        set --
        source ./"$meta"/setup-environment >/dev/null || exit 1
        eval "$cmd"
    ' _ "$(subdir_of "$BUILD_DIR")" "$PROD_META" "$1"
}

step_configure() {
    if [ -f "$(marker configure)" ]; then log "configure: done (marker)"; return; fi
    log "configure: setup-environment ($PROD_MACHINE) + pinned SRCREVs"
    in_build_env true
    local conf
    conf=$(subdir_of "$BUILD_DIR")/build-$PROD_MACHINE/conf
    [ -f "$conf/local.conf" ] || die "setup-environment did not create $conf/local.conf"
    cp "$PINS_DIR/srcrev.inc" "$conf/mvx-srcrev.inc"
    grep -q 'mvx-opensync' "$conf/local.conf" || cat >> "$conf/local.conf" <<EOF

# --- mvx-opensync (build-mvx.sh), pins: $MVX_PINS ---
require conf/mvx-srcrev.inc
DL_DIR = "$MVX_DL_DIR"
SSTATE_DIR = "$MVX_SSTATE_DIR"
EOF
    touch "$(marker configure)"
}

# Recipes whose shared-sstate output carries an absolute path into ANOTHER
# (possibly deleted) build dir, as seen in this round's bitbake output, e.g.
#   '/home/rev/yocto/<other-build>/build-*/tmp/work/<arch>/libwebsockets/.../libssl.so' ... missing
# (libwebsockets exports its recipe-sysroot libssl path in its cmake config;
# the sstate object was produced by a build dir that no longer exists).
foreign_path_recipes() {
    local out=$1 self
    self=$(basename "$BUILD_DIR")
    grep -aoE "$HOME/yocto/[^/ ]+/[^ ]*/tmp/work/[^/ ]+/[^/ ]+/" "$out" 2>/dev/null \
        | awk -F/ -v self="$self" -v home="$HOME" '
            { n = split(home, h, "/"); dir = $(n + 2)
              for (i = 1; i <= NF; i++) if ($i == "work") { r = $(i + 2); break }
              if (dir != self && r != "") print r }' | sort -u
}

step_bitbake() {
    if [ -f "$(marker built)" ]; then log "bitbake: done (marker)"; return; fi
    local round rc out recipes r t0
    out=$(mktemp)
    for round in 1 2 3; do
        log "bitbake: ofw (round $round)"
        t0=$SECONDS rc=0
        in_build_env 'bitbake ofw && bitbake-layers show-layers > layers.txt' > >(tee "$out") 2>&1 || rc=$?
        sleep 1   # let tee drain
        log "bitbake: exit $rc after $(( (SECONDS - t0) / 60 )) min"
        [ "$rc" -eq 0 ] && break
        recipes=$(foreign_path_recipes "$out")
        [ -n "$recipes" ] && [ "$round" -lt 3 ] || { rm -f "$out"; die "bitbake ofw failed"; }
        for r in $recipes; do
            warn "bitbake: $r came from sstate built in another build dir (stale absolute path); rebuilding it locally"
            in_build_env "bitbake -f -c configure $r" || { rm -f "$out"; die "forced rebuild of $r failed"; }
        done
    done
    rm -f "$out"
    [ -e "$(artifact)" ] || die "bitbake reported success but $(artifact) is missing"
    touch "$(marker built)"
}

step_verify() {
    local bdir img_bh image rc=0
    bdir=$(subdir_of "$BUILD_DIR")/build-$PROD_MACHINE
    img_bh=$(find "$bdir/buildhistory/images" -maxdepth 3 -type d -path '*/glibc/ofw' | head -1)
    image=$(readlink -f "$(artifact)")
    if diff -u "$PINS_DIR/installed-package-names.txt" "$img_bh/installed-package-names.txt" \
            > "$BUILD_DIR/mvx-package-names.diff"; then
        log "verify: installed packages identical to the reference ($(wc -l < "$img_bh/installed-package-names.txt"))"
    else
        warn "verify: installed packages differ, see $BUILD_DIR/mvx-package-names.diff"; rc=1
    fi
    python3 "$BUILD_DIR/openembedded-core/scripts/buildhistory-collect-srcrevs" -a \
        -p "$bdir/buildhistory" > "$BUILD_DIR/mvx-srcrevs.txt"
    # Compare the recipes both builds recorded. buildhistory only records what
    # a build actually ran, so recipes restored from sstate on either side are
    # legitimately absent from the other list.
    local mism
    mism=$(awk -F' = ' 'NR == FNR { if ($1 ~ /^SRCREV/) pin[$1] = $2; next }
                        $1 ~ /^SRCREV/ && ($1 in pin) && pin[$1] != $2 { print $1 ": pinned " pin[$1] ", built " $2 }' \
            "$PINS_DIR/srcrev.inc" "$BUILD_DIR/mvx-srcrevs.txt")
    printf '%s\n' "$mism" > "$BUILD_DIR/mvx-srcrevs.diff"
    if [ -z "$mism" ]; then
        log "verify: every SRCREV recorded by both builds matches the pins ($(grep -c '^SRCREV' "$BUILD_DIR/mvx-srcrevs.txt") recorded here)"
    else
        warn "verify: SRCREVs differ from the pins, see $BUILD_DIR/mvx-srcrevs.diff"; rc=1
    fi
    cat > "$BUILD_DIR/mvx-build-info.txt" <<EOF
pins=$MVX_PINS
product=$MVX_PRODUCT release=$MVX_RELEASE machine=$PROD_MACHINE
image=$image
image_sha256=$(sha256sum "$image" | awk '{print $1}')
reference_image_sha256=$(sed -n 's/^image_sha256=//p' "$PINS_DIR/reference.txt")
verify=$([ $rc -eq 0 ] && echo identical-packages-and-srcrevs || echo DIFFERS)
built_at=$(date -Is) on $(hostname)
EOF
    log "verify: image $image"
    return $rc
}

cmd_build() {
    BUILD_DIR=$MVX_BUILD_DIR
    local resume=false
    while [ $# -gt 0 ]; do
        case "$1" in
            --dir) BUILD_DIR=$2; shift 2 ;;
            --resume) resume=true; shift ;;
            *) die "build: unknown option $1" ;;
        esac
    done
    require_cmd repo git python3
    [ -f "$PINS_DIR/manifest.xml" ] || die "no pins at $PINS_DIR (run: $0 pin)"
    [ -d "$MVX_PIN_STORE/manifests.git" ] || die "no pin store at $MVX_PIN_STORE (run: $0 pin)"
    case "$(basename "$BUILD_DIR")" in
        "$MVX_PRODUCT"-lxd-r[0-9]*-oe[0-9]*-*) ;;
        *) die "build dir must be named $MVX_PRODUCT-lxd-<release>-<oe>-<suffix> (mv.sh parses it)" ;;
    esac
    if [ -e "$BUILD_DIR" ] && ! $resume; then
        die "$BUILD_DIR exists; pass --resume to continue it (a fresh build needs a new dir)"
    fi
    local avail
    avail=$(df -BG --output=avail "$(dirname "$BUILD_DIR")" | tail -1 | tr -dc 0-9)
    [ "$avail" -ge 100 ] || die "less than 100G free under $(dirname "$BUILD_DIR")"
    install -d "$BUILD_DIR"
    start_log "build-$(basename "$BUILD_DIR")"
    log "build: product=$MVX_PRODUCT release=$MVX_RELEASE pins=$MVX_PINS dir=$BUILD_DIR"

    setup_redirects
    step_checkout
    step_layers
    step_configure
    step_bitbake
    step_verify || warn "the build succeeded but differs from the reference (see above)"
    # setup-vm.sh / deploy-mvx.sh default to this build from now on
    persist_local MVX_BUILD_DIR "$BUILD_DIR"
    log "done: $(artifact)"
}

cmd_status() {
    BUILD_DIR=${1:-$MVX_BUILD_DIR}
    echo "build dir: $BUILD_DIR"
    local m
    for m in checkout layers configure built; do
        printf '  %-10s %s\n' "$m" "$([ -f "$(marker "$m")" ] && echo done || echo -)"
    done
    [ -e "$(artifact)" ] && echo "artifact:  $(readlink -f "$(artifact)")"
    [ -f "$BUILD_DIR/mvx-build-info.txt" ] && sed 's/^/  /' "$BUILD_DIR/mvx-build-info.txt"
    return 0
}

usage() { sed -n '3,9p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

cmd=${1:-}; [ $# -gt 0 ] && shift
case "$cmd" in
    pin)    cmd_pin "$@" ;;
    build)  cmd_build "$@" ;;
    all)    [ -f "$PINS_DIR/manifest.xml" ] || cmd_pin; cmd_build "$@" ;;
    status) cmd_status "$@" ;;
    *)      usage ;;
esac
