# roksbnk-argo-cd

Run the [roksbnkctl](https://github.com/jgruberf5/roksbnkctl) BNK lifecycle — `bnk up` with every guard, `bnk status`, `bnk down` — from declarations that **Argo CD** syncs into a ROKS cluster. No Argo Workflows.

The design and its rationale are in [`EVALUATION.md`](EVALUATION.md). In one paragraph: Argo CD is the sole orchestrator and source of truth; the workspace substrate (namespace, PVC, ServiceAccount, RBAC, ConfigMap, Secret) is synced as regular resources, and the imperative core — roksbnkctl driving Terraform with the IBM API key — runs inside Argo CD **hook Jobs** on the existing `roksbnkctl-tools-runner` image, ordered by sync phase and wave.

```
Sync     wave -10 Namespace · ServiceAccount · Role · RoleBinding · ConfigMap bnk-env · Secret
Sync     wave -4  PVC bnk-work    (same wave as the first hook: WaitForFirstConsumer binds here)
Sync     wave -4  bnk-init        init --non-interactive --override-from-env · doctor
Sync     wave -3  bnk-cluster     cluster register <name> (in-target)  |  cluster up --auto (hub)
Sync     wave -2  bnk-registry    registry adopt  |  registry replicate --target … (optional)
Sync     wave -1  bnk-preflight   workspace-file guards (mirror record, FLP hand-off, line change)
Sync     wave  0  bnk-up          bnk up --auto  (+ cwc-guard container on BNK 2.3)      ← lifecycle: up
                  bnk-down        bnk down --auto                                        ← lifecycle: down
Sync     wave  0  ConfigMap bnk-status (data owned by the hooks; Lua health → Application health)
PostSync wave  0  bnk-status      bnk status --json → ConfigMap bnk-status
SyncFail wave  0  bnk-syncfail    records the failure → Application Degraded with the reason
PreDelete         bnk-predelete   bnk down --auto when the Application is deleted (Argo CD ≥ 3.3)
```

The gates are *Sync-phase* hooks at negative waves rather than PreSync hooks: PreSync runs before any regular resource exists, so a PreSync Job would have no PVC, ConfigMap, Secret or ServiceAccount to start with (that was the first thing the kind harness caught). A failed gate fails the sync before the 45–90 minute apply starts. Syncing the Application *is* the "Apply this plan?" confirmation (manual sync, RBAC role `bnk-operator`, optional sync windows). Application health comes from a Lua check on the `bnk-status` ConfigMap the hooks write.

## Layout

```
bootstrap/                  one-time per Argo CD instance
  appproject-bnk.yaml         AppProject: destinations, whitelist, bnk-operator role
  health/bnk-status.lua       the health check (single source; embedded by `make bootstrap-render`)
  upstream/argocd-cm-health.yaml   upstream Argo CD wiring (hub / kind)
  openshift/gitops-subscription.yaml, argocd-cr.yaml   OpenShift GitOps wiring (in-target)
  external-secrets/           ClusterSecretStore example (IBM Secrets Manager)
charts/bnk-workspace/       the Helm chart: substrate + hook Jobs (values.yaml documents every knob)
apps/
  applicationset-workspaces.yaml   one Application per overlay
  overlays/<workspace>/values.yaml bnkconn (connected, in-target), bnkdisco (disconnected, hub), kind-stub
  kind-stub-application.yaml       local verification Application
hack/
  stub-runner/                stub roksbnkctl image reproducing verbs, guards, exit codes, workspace files
  kind/                       up.sh · publish.sh · demo.sh — Argo CD + git server + stub on kind
```

## Quick start (real cluster, in-target)

1. Install OpenShift GitOps: `kubectl apply -f bootstrap/openshift/gitops-subscription.yaml`, then `kubectl apply -f bootstrap/openshift/argocd-cr.yaml` and `kubectl apply -n openshift-gitops -f bootstrap/appproject-bnk.yaml`.
2. Provide `bnk-secrets` (`IBMCLOUD_API_KEY`, mirror/BIG-IP/GTM passwords as needed): `secrets.mode: externalSecret` with `bootstrap/external-secrets/`, or create it out of band (`secrets.mode: existing`).
3. Copy `apps/overlays/bnkconn/values.yaml`, set `cluster.name`, the `ROKSBNKCTL_*` keys and the storage class; point `apps/applicationset-workspaces.yaml` at your Git host; apply it.
4. **Sync** the Application (`argocd app sync bnk-<ws>` or the UI). Watch the hook Jobs: `kubectl -n bnk-<ws> get jobs -l roksbnkctl.io/workspace`.
5. Tear down: delete the Application (PreDelete → `bnk down`), or set `lifecycle: down` in the overlay and sync.

The PVC `bnk-work` is never pruned or deleted with the Application — it holds the Terraform state and the workspace hand-off files.

## Local verification (kind, no IBM Cloud)

```
export REPO_MOUNT=$HOME/.cache/roksbnk-argo-cd/kind-repo   # linux filesystem
make kind-up          # kind + Argo CD + in-cluster git server + stub runner + health check + AppProject
make kind-demo        # publish HEAD, create the Application, sync, wait, print hooks + status
hack/kind/demo.sh delete   # PreDelete → bnk down
```

Failure scenarios: set `STUB_FAIL_GUARD=<msg>` (guard fails inside `bnk up`), `STUB_FAIL_APPLY=<msg>` (apply fails), or `registry.mode: adopt` + `STUB_MIRROR_MISSING=3` (preflight gate fails) in `apps/overlays/kind-stub/values.yaml`, commit, `make kind-publish`, sync.

## Verified on kind (Argo CD v3.5.1, stub runner)

Transcripts in [`docs/verification/`](docs/verification/):

| Scenario | Result |
|---|---|
| 1 · `bnk up` | init → cluster → preflight → `bnk-up` → PostSync status; Application **Synced / Healthy — "BNK deployed"** |
| 2a · registry mirror incomplete | preflight gate fails at wave −1; **no `bnk-up` Job created**; SyncFail runs; **Degraded** with the reason |
| 2b · apply fails inside `bnk up` | `bnk-up` Failed; status trap + SyncFail; **Degraded — "bnk up exited with status 1"** |
| 3 · `lifecycle: down` | `bnk-down` → PostSync; **Healthy — "BNK torn down"**, `deployed=false` |
| 4 · redeploy, then delete the Application | PreDelete `bnk-predelete` ran `bnk down`; Application and its resources gone in ~12 s; **PVC retained** with the workspace state |

Things the harness caught that apply to a real cluster: gates must be Sync-phase hooks (above); a `WaitForFirstConsumer` PVC in its own wave deadlocks the sync (Argo CD waits for it to bind — `ignore-healthcheck` only affects Application health, not wave gating), hence the PVC shares wave −4; a Degraded resource at the end of the Sync phase fails the operation and skips PostSync (so the status must never be Degraded on a successful run — `jq '.deployed // …'` turning `false` into "unknown" did exactly that).

## Development

```
make lint       # helm lint every overlay (+ lifecycle=down, line=2.3)
make template   # render into .rendered/
make validate   # kubeconform (Kubernetes + Argo CD + ESO schemas)
```
