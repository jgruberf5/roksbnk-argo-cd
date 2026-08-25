#!/usr/bin/env bash
# Push the working tree's HEAD into the bare repo served by the in-cluster git
# server (dumb HTTP needs update-server-info after every push).
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
REPO_MOUNT=${REPO_MOUNT:?set REPO_MOUNT (same directory given to up.sh)}
BARE="$REPO_MOUNT/roksbnk-argo-cd.git"
[ -d "$BARE" ] || git init -q --bare "$BARE"
git -C "$ROOT" push -q --force "$BARE" HEAD:refs/heads/main
git --git-dir="$BARE" update-server-info
git --git-dir="$BARE" symbolic-ref HEAD refs/heads/main
echo "published $(git -C "$ROOT" rev-parse --short HEAD) → $BARE"
