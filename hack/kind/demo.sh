#!/usr/bin/env bash
# Drive the kind verification scenarios against the bnk-kindstub Application.
#
#   demo.sh create          create the Application (no sync)
#   demo.sh sync            sync = "Apply this plan?" → bnk up
#   demo.sh wait [phase]    wait for the operation to finish; print hooks + status
#   demo.sh status          Application sync/health + bnk-status ConfigMap
#   demo.sh hooks           hook Jobs in start order with their outcome
#   demo.sh logs <job>      logs of one hook Job
#   demo.sh delete          delete the Application (PreDelete → bnk down)
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
APP=${APP:-bnk-kindstub}
NS=${NS:-bnk-kindstub}
ARGONS=${ARGONS:-argocd}
export ARGOCD_OPTS="--core"
argo() { kubectl config set-context --current --namespace="$ARGONS" >/dev/null; argocd "$@"; }

case "${1:-status}" in
  create)
    kubectl apply -f "$ROOT/apps/kind-stub-application.yaml"
    argo app get "$APP" --refresh >/dev/null 2>&1 || true ;;
  sync)
    argo app sync "$APP" --async --prune >/dev/null
    echo "sync requested" ;;
  wait)
    argo app wait "$APP" --operation --timeout "${2:-900}" || true
    "$0" hooks; "$0" status ;;
  status)
    kubectl -n "$ARGONS" get application "$APP" -o jsonpath='{"sync: "}{.status.sync.status}{"  health: "}{.status.health.status}{"  op: "}{.status.operationState.phase}{" — "}{.status.operationState.message}{"\n"}'
    kubectl -n "$NS" get configmap bnk-status -o jsonpath='{"bnk-status: lifecycle="}{.data.lifecycle}{" outcome="}{.data.outcome}{" deployed="}{.data.deployed}{" hook="}{.data.lastHook}{"\n  "}{.data.message}{"\n"}' 2>/dev/null || echo "bnk-status: (absent)" ;;
  hooks)
    kubectl -n "$NS" get jobs -l roksbnkctl.io/workspace --sort-by=.metadata.creationTimestamp \
      -o custom-columns='HOOK:.metadata.annotations.argocd\.argoproj\.io/hook,WAVE:.metadata.annotations.argocd\.argoproj\.io/sync-wave,JOB:.metadata.name,STARTED:.status.startTime,SUCCEEDED:.status.succeeded,FAILED:.status.failed' 2>/dev/null || true ;;
  logs)
    kubectl -n "$NS" logs "job/${2:?job name}" --all-containers ;;
  delete)
    kubectl -n "$ARGONS" delete application "$APP" --wait=false
    echo "delete requested (PreDelete hook runs bnk down before resources go)" ;;
  *) echo "usage: $0 create|sync|wait|status|hooks|logs <job>|delete" >&2; exit 2 ;;
esac
