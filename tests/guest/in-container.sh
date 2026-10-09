#!/usr/bin/env bash
#
# tests/guest/in-container.sh - tests/guest/run.sh in a throwaway container, offline (no
# network): the guest steps run as root and write /etc, /usr/local and /var/lib, which a host
# must not get. The image is local-noc's base (bash, coreutils, python3 for the steps'
# one-liners); the repository is mounted read-only.
#
#   tests/guest/in-container.sh      (GUEST_TEST_IMAGE overrides the image)

set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
IMAGE=${GUEST_TEST_IMAGE:-python:3.12-slim}
exec docker run --rm --network none -v "$ROOT:/opt/opensync-lab:ro" "$IMAGE" \
    bash /opt/opensync-lab/tests/guest/run.sh
