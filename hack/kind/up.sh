#!/usr/bin/env bash
# Bring up a local kind cluster with Argo CD, an in-cluster dumb-HTTP git server
# that serves this repository, and the stub runner image. Used to verify the
# Argo CD mechanics (phases, waves, hooks, health) without IBM Cloud.
#
#   REPO_MOUNT   host dir that will be mounted into the kind node at /repo;
#                the bare repo <REPO_MOUNT>/roksbnk-argo-cd.git is served over HTTP.
#   ARGOCD_VERSION  Argo CD manifest version to install (default: argocd CLI version).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
CLUSTER=${CLUSTER:-bnk-argocd}
REPO_MOUNT=${REPO_MOUNT:?set REPO_MOUNT to a host directory (linux filesystem, not /mnt/*)}
ARGOCD_VERSION=${ARGOCD_VERSION:-$(argocd version --client -o json 2>/dev/null | sed -n 's/.*"Version": *"v\([^"+]*\).*/\1/p' | head -1)}
ARGOCD_VERSION=${ARGOCD_VERSION:-3.5.1}
STUB_IMAGE=${STUB_IMAGE:-roksbnkctl-stub:dev}

mkdir -p "$REPO_MOUNT"
if ! kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
  sed "s#__REPO_MOUNT__#$REPO_MOUNT#" "$HERE/kind-config.yaml.tmpl" > "$REPO_MOUNT/kind-config.yaml"
  kind create cluster --name "$CLUSTER" --config "$REPO_MOUNT/kind-config.yaml" --wait 120s
fi
kubectl config use-context "kind-$CLUSTER" >/dev/null

echo ">> Argo CD v$ARGOCD_VERSION"
kubectl get ns argocd >/dev/null 2>&1 || kubectl create ns argocd
kubectl apply -n argocd --server-side --force-conflicts \
  -f "https://raw.githubusercontent.com/argoproj/argo-cd/v${ARGOCD_VERSION}/manifests/install.yaml" >/dev/null

echo ">> git server (smart HTTP over the mounted bare repo)"
docker build -q -t git-http:dev "$HERE/git-http" >/dev/null
kind load docker-image --name "$CLUSTER" git-http:dev
kubectl apply -f "$HERE/gitserver.yaml" >/dev/null

echo ">> stub runner image"
docker build -q -t "$STUB_IMAGE" "$ROOT/hack/stub-runner" >/dev/null
kind load docker-image --name "$CLUSTER" "$STUB_IMAGE"

echo ">> Argo CD customisations (health check, AppProject)"
kubectl apply -f "$ROOT/bootstrap/upstream/argocd-cm-health.yaml" >/dev/null
kubectl apply -n argocd -f "$ROOT/bootstrap/appproject-bnk.yaml" >/dev/null

kubectl -n argocd rollout status deploy/argocd-repo-server --timeout=300s
kubectl -n argocd rollout status deploy/argocd-server --timeout=300s
kubectl -n argocd rollout status statefulset/argocd-application-controller --timeout=300s
kubectl -n git rollout status deploy/gitserver --timeout=120s
# the repo-server caches argocd-cm; restart so the health Lua is picked up immediately
kubectl -n argocd rollout restart deploy/argocd-repo-server statefulset/argocd-application-controller >/dev/null
echo ">> ready: context kind-$CLUSTER"
