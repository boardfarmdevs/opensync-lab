#!/usr/bin/env bash
# boardfarm-lab-staging: pinned checkout, uv venv, the opensync-lab lab config
# config overlay, then bf-lab setup (dhcp-cpe1 + wan-cpe1 + lan-cpe1).
source "$(dirname "$0")/common.sh"

BF=/opt/boardfarm
REPO=$BF/boardfarm-lab-staging
bundle=$MVX_GUEST_ROOT/assets/boardfarm-lab-staging.bundle
commit=${MVX_BOARDFARM_COMMIT:?}

install -d "$BF"
if [ ! -d "$REPO/.git" ]; then
    git clone -q "$bundle" "$REPO"
else
    git -C "$REPO" fetch -q "$bundle" 'refs/heads/*:refs/remotes/bundle/*'
fi
# pinned commit + this repo's patch set, reapplied from scratch every run
# (untracked files -- the lab config overlay -- are left alone)
git -C "$REPO" checkout -q -B mvx-pin "$commit"
git -C "$REPO" reset -q --hard "$commit"
[ "$(git -C "$REPO" rev-parse HEAD)" = "$commit" ] || die "boardfarm not at $commit"
log "boardfarm: $(git -C "$REPO" log -1 --format='%h %s')"
for p in "$MVX_GUEST_ROOT"/boardfarm/patches/*.patch; do
    [ -e "$p" ] || continue
    git -C "$REPO" apply "$p" || die "boardfarm patch does not apply: $(basename "$p")"
    log "boardfarm: applied $(basename "$p")"
done
# The patches change image contents (resources/*); bf-lab only builds images
# that are missing, so drop the service images when the patch set changed.
patch_sum=$(cat "$MVX_GUEST_ROOT"/boardfarm/patches/*.patch 2>/dev/null | sha256sum | cut -d' ' -f1)
if [ "$(cat "$STATE/boardfarm-patches.sha256" 2>/dev/null)" != "$patch_sum" ]; then
    log "boardfarm: patch set changed, dropping service images for a rebuild"
    docker rm -f dhcp-cpe1 wan-cpe1 lan-cpe1 >/dev/null 2>&1 || true
    docker rmi -f bf-dhcp-kea:bookworm bf-wan:bookworm bf-lan:bookworm >/dev/null 2>&1 || true
    echo "$patch_sum" > "$STATE/boardfarm-patches.sha256"
fi

# overlay: lab configs must live in lab/ (relative base/resources paths)
cp "$MVX_GUEST_ROOT"/boardfarm/lab/*.json "$REPO/lab/"

if [ ! -x "$BF/.venv/bin/bf-lab" ]; then
    log "boardfarm: uv venv + install"
    uv venv -q --python /usr/bin/python3 "$BF/.venv"
fi
VIRTUAL_ENV=$BF/.venv uv pip install -q -e "$REPO"
"$BF/.venv/bin/python" -c 'import lab.lab' || die "boardfarm import failed"

cat > /etc/default/boardfarm-lab <<EOF
BF_LAB_CONFIG=opensync-lab.json
BOARDFARM_WORKSPACE=$BF
EOF
cat > /etc/profile.d/boardfarm-lab.sh <<EOF
export BF_LAB_CONFIG=opensync-lab.json
export PATH=$BF/.venv/bin:\$PATH
EOF

install -m 0755 "$MVX_GUEST_ROOT/guest/files/boardfarm-lab-rebuild" /usr/local/sbin/
install -m 0644 "$MVX_GUEST_ROOT/guest/files/boardfarm-lab.service" /etc/systemd/system/
systemctl daemon-reload
systemctl enable boardfarm-lab.service >/dev/null 2>&1

log "boardfarm: bf-lab setup (first run builds the docker images)"
systemctl restart boardfarm-lab.service || { journalctl -u boardfarm-lab.service -n 80 --no-pager; die "bf-lab setup failed"; }
systemctl restart mvx-lxd-docker-forward.service

set_status boardfarm "ok $(git -C "$REPO" rev-parse --short HEAD) $(docker ps --format '{{.Names}}' | sort | paste -sd, -)"
log "boardfarm: $(cat "$STATE/boardfarm.status")"
