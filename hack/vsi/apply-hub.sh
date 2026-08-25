#!/usr/bin/env bash
# apply-hub.sh — wire a freshly bootstrapped hub to this repository and a
# workspace: the bnk-status health check, the AppProject, a read-only Git deploy
# key, the workspace namespace + bnk-secrets, and the Application. Everything
# runs over ssh; the k3s API is never exposed.
#
#   set -a; source "$HUB_STATE/hub.env"; set +a
#   IBMCLOUD_API_KEY=… GIT_DEPLOY_KEY=~/.ssh/argocd-deploy-key WORKSPACE=sm-cli bash hack/vsi/apply-hub.sh
set -euo pipefail
: "${HUB_FIP:?source hub.env}"; : "${HUB_SSH_KEY_FILE:?source hub.env}"
: "${IBMCLOUD_API_KEY:?set IBMCLOUD_API_KEY}"
: "${GIT_DEPLOY_KEY:?path to the read-only deploy key registered on the repo}"
WORKSPACE="${WORKSPACE:?workspace overlay name, e.g. sm-cli}"
GIT_URL="${GIT_URL:-git@github.com:jgruberf5/roksbnk-argo-cd.git}"
APP_FILE="${APP_FILE:-apps/${WORKSPACE}-application.yaml}"
NS="${NS:-bnk-${WORKSPACE}}"
ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../.." && pwd)"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=20"
# non-interactive ssh does not source .bashrc: pin the ubuntu user's kubeconfig
V(){ ssh -i "$HUB_SSH_KEY_FILE" $SSH_OPTS ubuntu@"$HUB_FIP" "export KUBECONFIG=/home/ubuntu/.kube/config; $*"; }
say(){ echo "==> $*" >&2; }

# 1. Argo CD customisations from the repo
V 'mkdir -p ~/bootstrap'
scp -i "$HUB_SSH_KEY_FILE" $SSH_OPTS -q "$ROOT/bootstrap/upstream/argocd-cm-health.yaml" "$ROOT/bootstrap/appproject-bnk.yaml" "$ROOT/$APP_FILE" ubuntu@"$HUB_FIP":~/bootstrap/
V 'kubectl apply -f ~/bootstrap/argocd-cm-health.yaml && kubectl apply -n argocd -f ~/bootstrap/appproject-bnk.yaml' >&2

# 2. Repository credential (read-only deploy key) — never leaves the pipe unencrypted
V "kubectl -n argocd create secret generic repo-roksbnk-argo-cd --from-literal=type=git --from-literal=url='$GIT_URL' --from-file=sshPrivateKey=/dev/stdin --dry-run=client -o yaml | kubectl label --local -f - argocd.argoproj.io/secret-type=repository -o yaml | kubectl apply -f -" < "$GIT_DEPLOY_KEY" >&2

# 3. Workspace namespace + secrets (secrets.mode: existing)
V "kubectl create namespace '$NS' --dry-run=client -o yaml | kubectl apply -f -" >&2
# printf, not a here-string: <<< appends a newline and IAM then rejects the key
printf '%s' "$IBMCLOUD_API_KEY" | V "kubectl -n '$NS' create secret generic bnk-secrets --from-file=IBMCLOUD_API_KEY=/dev/stdin --dry-run=client -o yaml | kubectl apply -f -" >&2

# 4. Pick up the health check, then the Application
V 'kubectl config set-context --current --namespace=argocd >/dev/null; kubectl -n argocd rollout restart deploy/argocd-repo-server statefulset/argocd-application-controller >/dev/null; kubectl -n argocd rollout status statefulset/argocd-application-controller --timeout=180s >/dev/null' >&2
V "kubectl apply -f ~/bootstrap/$(basename "$APP_FILE")" >&2
sleep 5
V "argocd --core app get $(V "kubectl -n argocd get -f ~/bootstrap/$(basename "$APP_FILE") -o jsonpath={.metadata.name}") --refresh 2>&1 | sed -n '1,12p;/^Sync Status/p;/^Health Status/p'" >&2 || true
say "applied. sync with:  ssh -i $HUB_SSH_KEY_FILE ubuntu@$HUB_FIP argocd --core app sync <app>"
