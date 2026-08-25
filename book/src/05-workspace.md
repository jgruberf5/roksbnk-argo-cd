# Step 2 — Describe the workspace

A workspace is one BNK installation on one cluster. In Git it is one values
file and one `Application`. This chapter walks through the values file for the
cluster this book installs onto — `sm-cli`, an existing ROKS 4.21 cluster —
and explains what each block means.

## The size comes first

Before any other setting, decide the **cluster size**. F5's sizing guide
defines three; roksbnkctl has verified each on ROKS. Pick the row, and the
chart fills in the node count, the node flavour and the TMM pod count:

| `sizing.profile` | Worker nodes | Flavour | TMM pods | L4 ingress (F5 figure) |
|---|---|---|---|---|
| `small` | **6** (2 per zone) | **`bx2.8x32`** | 3 | ~7.8 Gbit/s |
| `medium` | **6** (2 per zone) | **`cx2.16x32`** | 3 | ~10.4 Gbit/s |
| `large` | **9** (3 per zone) | **`cx2.48x96`** | 9 | ~31 Gbit/s |
| `baseline` | 3 (1 per zone) | `bx2.16x64` | 1 | the BNK 2.4 install-guide shape |

> **`deploymentSize` is always `Tiny` on ROKS.** The words Small, Medium and
> Large above are cluster sizes. They are *not* the BNK `CNEInstance`
> `deploymentSize`, which accepts the same words but means something else — and
> on ROKS every value other than `Tiny` requests hugepages that ROKS workers
> cannot provide, so the install fails silently. Capacity comes from the number
> of TMM pods and the size of the nodes; the Large cluster runs nine `Tiny`
> TMMs on nine big nodes. The chart refuses to render any other
> `deploymentSize` on the 2.4 line (`sizing.allowNonTinyDeploymentSize` exists
> for people who have read this paragraph and disagree). [Chapter 9](09-sizing.md)
> has the full story.

`sm-cli` has six `bx2.8x32` workers, two per zone: it **is** the Small cluster.

## The values file

`apps/overlays/sm-cli/values.yaml`:

```yaml
workspace: sm-cli              # roksbnkctl workspace name
namespace: bnk-sm-cli          # where the hook Jobs and the PVC live
lifecycle: up                  # up = install (bnk up); down = uninstall (bnk down)
topology: hub                  # Argo CD on a management cluster; in-target if it runs on the ROKS cluster
line: "2.4"
sizing:
  profile: small               # 6× bx2.8x32, 3 TMM pods, deploymentSize Tiny

runner:
  tag: v1.54.0
  runAsUser: 1000              # k3s hub; leave unset on OpenShift

cluster:
  create: false                # install onto an existing cluster …
  name: sm-cli                 # … this one (cluster register)
  registryCosName: sm-cli-registry-cos

registry:
  mode: none                   # connected: pull straight from F5's registry (FAR)

storage:
  size: 8Gi
  storageClassName: local-path # ibmc-vpc-block-10iops-tier on ROKS

secrets:
  mode: existing               # bnk-secrets was created in Step 1

env:                           # every ROKSBNKCTL_* key roksbnkctl init accepts
  ROKSBNKCTL_REGION: us-east
  ROKSBNKCTL_RESOURCE_GROUP: default
  ROKSBNKCTL_PREFIX: sm-cli
  ROKSBNKCTL_OPENSHIFT_VERSION: "4.21"
  ROKSBNKCTL_CLUSTER_NETWORK_MODE: single-nic
  ROKSBNKCTL_TRANSIT_GATEWAY_NAME: sm-cli-tgw      # the gateway the cluster VPC is on
  ROKSBNKCTL_MANIFEST_VERSION: 2.4.0-EA            # selects the 2.4 line
  ROKSBNKCTL_FAR_AUTH_FILE: non-ga-prod-pull-key.tgz
  ROKSBNKCTL_SUBSCRIPTION_JWT_FILE: subscription.jwt
  ROKSBNKCTL_COS_INSTANCE: bnk-supply-chain
  ROKSBNKCTL_COS_BUCKET: bnk-artifacts-0b5a00334eaf
  ROKSBNKCTL_COS_REGION: us-south
```

Block by block:

- **`lifecycle`** is the switch you will flip in Part IV. `up` renders a
  `bnk-up` hook; `down` renders `bnk-down` instead.
- **`sizing.profile`** writes `ROKSBNKCTL_WORKERS_PER_ZONE`,
  `ROKSBNKCTL_WORKER_FLAVOR`, `ROKSBNKCTL_TMM_REPLICAS` and
  `ROKSBNKCTL_CNEINSTANCE_SIZE=Tiny` into the `bnk-env` ConfigMap. With
  `cluster.create: false` the first two describe the cluster you already have;
  `tmmReplicas` is what BNK actually uses.
- **`cluster`** — `create: false` + `name` means the `bnk-cluster` hook runs
  `cluster register sm-cli`, records the cluster's VPC, network mode and
  registry COS instance in `cluster-outputs.json`, and fetches the admin
  kubeconfig. `create: true` (hub only) runs `cluster up` and builds the
  cluster the size profile describes — that is how the `bnk-small`,
  `bnk-medium` and `bnk-large` overlays work.
- **`registry.mode: none`** — a connected cluster pulls BNK from `repo.f5.com`
  with the FAR pull key from the COS bucket. `adopt` or `replicate` are for a
  Harbor/Artifactory mirror (disconnected clusters).
- **`env`** — the supply chain (COS instance, bucket, region, the two object
  names) and the cluster facts. The chart merges the profile and the
  chart-derived keys underneath; anything you set here wins.

## What the runner will see

Render it locally to check the environment the hooks will get:

```bash
helm template bnk-sm-cli charts/bnk-workspace -f apps/overlays/sm-cli/values.yaml \
  | sed -n '/kind: ConfigMap/,/^---/p' | grep -A30 'name: bnk-env'
```

```yaml
data:
  REGISTRY_COS_NAME: "sm-cli-registry-cos"
  ROKSBNKCTL_CLUSTER_CREATE: "false"
  ROKSBNKCTL_CLUSTER_NAME: "sm-cli"
  ROKSBNKCTL_CLUSTER_NETWORK_MODE: "single-nic"
  ROKSBNKCTL_CNEINSTANCE_SIZE: "Tiny"
  ROKSBNKCTL_COS_BUCKET: "bnk-artifacts-0b5a00334eaf"
  …
  ROKSBNKCTL_TMM_REPLICAS: "3"
  ROKSBNKCTL_WORKERS_PER_ZONE: "2"
  ROKSBNKCTL_WORKER_FLAVOR: "bx2.8x32"
```

`make lint` runs `helm lint` over every overlay, and `make validate` checks the
rendered manifests against the Kubernetes and Argo CD schemas.

## The Application

`apps/sm-cli-application.yaml` points Argo CD at the chart and the overlay:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: bnk-sm-cli
  namespace: argocd
  finalizers: [resources-finalizer.argocd.argoproj.io]   # delete → PreDelete hook (bnk down) first
spec:
  project: bnk
  sources:
    - repoURL: git@github.com:jgruberf5/roksbnk-argo-cd.git
      targetRevision: main
      path: charts/bnk-workspace
      helm:
        releaseName: bnk-sm-cli
        valueFiles: ["$values/apps/overlays/sm-cli/values.yaml"]
    - repoURL: git@github.com:jgruberf5/roksbnk-argo-cd.git
      targetRevision: main
      ref: values
  destination:
    server: https://kubernetes.default.svc
    namespace: bnk-sm-cli
  ignoreDifferences:
    - kind: ConfigMap
      name: bnk-status
      jsonPointers: ["/data"]        # the hooks own the status
  syncPolicy:
    syncOptions: [CreateNamespace=true, RespectIgnoreDifferences=true, PruneLast=true]
    retry: {limit: 0}                # never re-run bnk up automatically
```

Commit the overlay and the Application, push, and apply the Application:

```bash
git add apps/overlays/sm-cli apps/sm-cli-application.yaml
git commit -m "sm-cli workspace" && git push
kubectl apply -f apps/sm-cli-application.yaml
```

For a fleet, add the workspace to `apps/applicationset-workspaces.yaml`
instead; the ApplicationSet renders the same Application per entry.

The Application appears **OutOfSync / Missing** — Argo CD has rendered the
chart but nothing is applied yet. That is the starting line for Step 3.
