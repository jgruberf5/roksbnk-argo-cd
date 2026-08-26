# Hooks, waves and RBAC

## The Jobs

Every hook is a `batch/v1 Job` rendered by `charts/bnk-workspace/templates/hooks/`,
running the runner image with your `config.yaml` (the `bnk-config` ConfigMap)
mounted at `/config`, the `bnk-secrets` Secret, the workspace PVC at `/work`,
and `backoffLimit: 0` (a
failed hook is never retried silently — you re-sync).

| Job | Phase / wave | Command | Deadline (`timeouts.*`) |
|---|---|---|---|
| `bnk-init` | Sync / −4 | `roksbnkctl init -w $WS --config-file /config/config.yaml --override-from-env` (the file, then the Secret on top) · `roksbnkctl version` · `roksbnkctl -w $WS doctor` | `init` |
| `bnk-cluster` | Sync / −3 | `cluster register <config.cluster.name> --registry-cos-name …` **or** `cluster up --auto` (`config.cluster.create: true`), then `kubeconfig --download` | `cluster` |
| `bnk-registry` | Sync / −2 | `registry adopt` **or** `registry target` · `bom` · `replicate --target …` · `verify` (only when `registry.mode ≠ none`) | `registry` |
| `bnk-preflight` | Sync / −1 | shell replica of the workspace-file guards, then `bnk status --json` | `preflight` |
| `bnk-up` / `bnk-down` | Sync / 0 | `bnk up --auto` **or** `bnk down --auto`; writes `bnk-status` running → succeeded/failed | `apply` / `down` |
| `bnk-status` | PostSync / 0 | `bnk status --json` → `bnk-status`; `bnk status` (human) | `status` |
| `bnk-syncfail` | SyncFail / 0 | lists the failed Jobs, writes `outcome: failed` with the reason | `status` |
| `bnk-predelete` | PreDelete | `bnk down --auto` (+ `tgw disconnect`, `cluster down` with `teardown.cluster`) | `down` |

Hooks skipped when `lifecycle: down`: `bnk-cluster`, `bnk-registry`,
`bnk-preflight` (the state they would produce is already on the PVC).

All hooks use `argocd.argoproj.io/hook-delete-policy: BeforeHookCreation`: the
previous run's Job stays — with its logs — until the next sync replaces it.

## The shell prelude

Every hook script starts with the same prelude (`_helpers.tpl`):

- `local_kubectl` — kubectl against the cluster the Job runs in, using the pod's
  ServiceAccount token, never the ROKS admin kubeconfig (which may belong to a
  different cluster in the hub topology).
- `write_status <outcome> <deployed> <message> [status.json]` — merge-patches
  the `bnk-status` ConfigMap's `data` only, so Argo CD's tracking metadata is
  untouched.
- `deployed_now` — `bnk status --json | jq` with a filter that treats `false`
  as a value (a naive `.deployed // "unknown"` turns `false` into "unknown").

`bnk-up`/`bnk-down` trap `EXIT`: on a non-zero exit they write
`outcome: failed` with the exit status, touch `/signal/done` so a cwc-guard
container stops, and let the Job fail.

## Regular resources

| Resource | Wave | Notes |
|---|---|---|
| `Namespace` (optional) | −20 | `Prune=false,Delete=false` |
| `ServiceAccount`, `Role`, `RoleBinding`, `ConfigMap bnk-config` (your `config.yaml`), `ConfigMap bnk-env` (a few hook-internal keys), `Secret` / `ExternalSecret` | −10 | |
| `PersistentVolumeClaim bnk-work` | −4 | `Prune=false,Delete=false`, `ignore-healthcheck` — shares the first hook's wave so a WaitForFirstConsumer class binds inside the wave |
| `ConfigMap bnk-status` | 0 | placeholder data; the hooks own `data`; Application `ignoreDifferences` on `/data` |

## RBAC

The runner's ServiceAccount is deliberately narrow — roksbnkctl talks to IBM
Cloud and to the ROKS API with the API key, not with this identity:

```yaml
rules:
  - apiGroups: [""]
    resources: [configmaps]
    verbs: [get, list, create, patch, update]      # bnk-status
  - apiGroups: [batch]
    resources: [jobs]
    verbs: [get, list]                              # SyncFail names the failed hooks
  # with flpHandoff.writeSecret: create on secrets, get/update/patch on the named hand-off Secret
```

Argo CD itself, through the `bnk` AppProject, may manage namespaced resources
in `bnk-*` namespaces and the `Namespace` kind — nothing else cluster-scoped.
The project defines a `bnk-operator` role (`applications: get, sync, logs`) so
that the people who may press **Sync** are not the people who may edit the
Application.

## The health check

`bootstrap/health/bnk-status.lua` is the single source; `make bootstrap-render`
embeds it into `bootstrap/upstream/argocd-cm-health.yaml`
(`resource.customizations.health.ConfigMap`) and
`bootstrap/openshift/argocd-cr.yaml` (`spec.resourceHealthChecks`). Any
ConfigMap without the `roksbnkctl.io/status: "true"` label is reported
Healthy, so the override is invisible to other Applications.

## Application

```yaml
spec:
  project: bnk
  sources:
    - repoURL: git@github.com:jgruberf5/roksbnk-argo-cd.git
      path: charts/bnk-workspace
      helm:
        valueFiles: ["$values/apps/overlays/<workspace>/values.yaml"]
    - repoURL: git@github.com:jgruberf5/roksbnk-argo-cd.git
      ref: values
  destination: {server: https://kubernetes.default.svc, namespace: bnk-<workspace>}
  ignoreDifferences:
    - {kind: ConfigMap, name: bnk-status, jsonPointers: ["/data"]}
  syncPolicy:
    syncOptions: [CreateNamespace=true, RespectIgnoreDifferences=true, PruneLast=true]
    retry: {limit: 0}
```

Manual sync, no automated retry: a failed apply is something a person looks at.
`apps/applicationset-workspaces.yaml` renders the same shape for a list of
workspaces.
