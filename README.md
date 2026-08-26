# roksbnk-argo-cd

**Deploy F5 BIG-IP Next for Kubernetes (BNK) onto IBM Cloud ROKS with Argo CD — and nothing else.**

This repository runs the [roksbnkctl](https://github.com/jgruberf5/roksbnkctl) BNK lifecycle — `bnk up` with every guard and check, `bnk status`, `bnk down` — from declarations that Argo CD syncs into a ROKS cluster. It replaces the Argo *Workflows* CI demos that shipped with roksbnkctl for customers who standardise on Argo CD only.

- **[`EVALUATION.md`](EVALUATION.md)** — the discovery study behind this design: what `bnk up` really does, what Argo CD can and cannot express, the candidate designs, guard-by-guard mapping, containers, effort, and the results of verifying the scaffold on kind.
- **[`docs/verification/`](docs/verification/)** — transcripts of the five verified scenarios.

> Status: scaffold, verified on kind (Argo CD v3.5.1) with a stub runner. Not yet run against a live ROKS cluster — see [Running it for real](#running-it-for-real).

---

## How it works

Argo CD is the sole orchestrator and source of truth. The *workspace substrate* (namespace, PVC, ServiceAccount, RBAC, ConfigMap, Secret) is synced as ordinary resources. The *imperative core* — roksbnkctl driving Terraform with the IBM API key, exactly as it does on a laptop or in the Workflows demos — runs inside Argo CD **hook Jobs** on the existing `ghcr.io/jgruberf5/roksbnkctl-tools-runner` image, ordered by sync phase and sync wave:

```
Sync     wave -10  Namespace · ServiceAccount · Role · RoleBinding · ConfigMap bnk-config (config.yaml) · Secret bnk-secrets
Sync     wave  -4  PVC bnk-work          (shares the first hook's wave: WaitForFirstConsumer binds here)
Sync     wave  -4  bnk-init              init --config-file /config/config.yaml · doctor
Sync     wave  -3  bnk-cluster           cluster register <name> (in-target)  |  cluster up --auto (hub)
Sync     wave  -2  bnk-registry          registry adopt  |  registry replicate --target … (optional)
Sync     wave  -1  bnk-preflight         workspace-file guards: mirror record, FLP hand-off, line change
Sync     wave   0  bnk-up                bnk up --auto  (+ cwc-guard container on BNK 2.3)      ← lifecycle: up
                   bnk-down              bnk down --auto                                        ← lifecycle: down
Sync     wave   0  ConfigMap bnk-status  written by the hooks; Lua health → Application health
PostSync wave   0  bnk-status            bnk status --json → ConfigMap bnk-status
SyncFail wave   0  bnk-syncfail          records the failed hooks + reason → Application Degraded
PreDelete          bnk-predelete         bnk down --auto when the Application is deleted (Argo CD ≥ 3.3)
```

What this gives the operator:

| roksbnkctl on a laptop | With Argo CD |
|---|---|
| `roksbnkctl init` + `config.yaml` | the same `config.yaml`, under `config:` in `apps/overlays/<workspace>/values.yaml` → the `bnk-config` ConfigMap → `init --config-file` |
| API key prompt / keychain | `bnk-secrets` from External Secrets Operator (IBM Secrets Manager, Vault) or created out of band |
| "Apply this plan?" | **manual sync** — an audited action by the `bnk-operator` role, optionally inside a sync window |
| guards abort before the apply | gate Jobs at waves −4…−1 fail the sync; `bnk-up` is never created |
| `bnk status` | Application health: *Healthy — "BNK deployed"*, *Progressing*, *Degraded — reason* |
| `bnk down` | delete the Application (PreDelete hook) or set `lifecycle: down` and sync |
| workspace directory | PVC `bnk-work`, never pruned, never deleted with the Application |

The gates are Sync-phase hooks rather than PreSync hooks on purpose: PreSync runs before any regular resource exists, so a PreSync Job would have no PVC, ConfigMap, Secret or ServiceAccount to start with.

---

## Repository layout

```
bootstrap/                      one-time, per Argo CD instance
  appproject-bnk.yaml             AppProject: destinations, whitelist, bnk-operator role, sync windows
  health/bnk-status.lua           the health check (single source; `make bootstrap-render` embeds it)
  upstream/argocd-cm-health.yaml  upstream Argo CD wiring (hub / kind)
  openshift/                      OpenShift GitOps wiring (in-target): Subscription + ArgoCD CR
  external-secrets/               ClusterSecretStore example (IBM Secrets Manager)
charts/bnk-workspace/           the Helm chart: substrate + hook Jobs (values.yaml documents every knob)
apps/
  applicationset-workspaces.yaml  one Application per overlay
  overlays/bnkconn/               connected cluster, in-target topology
  overlays/sm-cli-mirror/         sm-cli again, from a private registry (Artifactory) + an external F5 License Proxy
  overlays/kind-stub/             local verification
  kind-stub-application.yaml      local verification Application
hack/
  stub-runner/                    stub roksbnkctl image: same verbs, guards, exit codes, workspace files
  kind/                           up.sh · publish.sh · demo.sh · smart-HTTP git server
docs/verification/              transcripts of the verified scenarios
EVALUATION.md                   the discovery study
```

---

## Prerequisites

| | |
|---|---|
| Argo CD | OpenShift GitOps (in-target) or upstream Argo CD ≥ 3.3 (hub). PreDelete hooks need ≥ 3.3; older versions use the `lifecycle: down` path. |
| Runner image | `ghcr.io/jgruberf5/roksbnkctl-tools-runner:v1.55.1` — roksbnkctl **≥ 1.55.1 required** (terraform ≥ 1.10, helm, kubectl/oc, ibmcloud). Mirror it for air-gapped sites. |
| IBM Cloud | An API key with VPC, Kubernetes Service, Transit Gateway and COS access, held in `bnk-secrets` as `IBMCLOUD_API_KEY`. roksbnkctl mints the ROKS admin kubeconfig from it; the pod ServiceAccount is never used against ROKS. |
| Supply chain | The FAR auth tarball and subscription JWT in the COS bucket named in `config.cos`, with the object names in `config.bnk.far_auth_file` / `config.bnk.subscription_jwt_file`. |
| Storage | An RWO storage class for the workspace PVC (`ibmc-vpc-block-10iops-tier` on ROKS). |
| Egress from the hook pods | IBM Cloud APIs, the ROKS API endpoint, FAR or the mirror, `releases.hashicorp.com` unless the Terraform plugin cache is pre-seeded. Disconnected clusters therefore use the hub topology. |

---

## Topologies

**In-target** (`topology: in-target`, default) — OpenShift GitOps runs on the ROKS cluster that receives BNK; hook Jobs run there too. The cluster must already exist (`cluster register`). Recommended for connected clusters.

**Hub** (`topology: hub`) — Argo CD runs on a management cluster (for the disconnected demos, the services-VPC k3s VSI that the roksbnkctl demos already bootstrap). The driver Application targets the hub; roksbnkctl reaches the ROKS API and the Harbor mirror over the Transit Gateway. Required for disconnected clusters, and the only place `cluster.create: true` (`cluster up`) makes sense.

---

## Running it for real

### 0. Option: build the hub VSI (upstream Argo CD in the fabric)

`hack/vsi/` builds the hub topology from a clean slate, adapted from roksbnkctl's Argo Workflows VSI bootstrap: a VPC with a chosen prefix, subnet, public gateway, one connection per Transit Gateway (**by name or id**, overlap-checked against every VPC already on them), and a `bx2-4x16` VSI running k3s + upstream Argo CD behind a floating IP. No Harbor — the connected BNK 2.4 path pulls from FAR.

```bash
export IBMCLOUD_API_KEY=…
export HUB_STATE=$HOME/.cache/roksbnk-argo-cd/hub-state          # Linux filesystem
TGWS="bnkci-testing sm-cli-tgw" HUB_REGION=us-south HUB_CIDR=10.250.0.0/24 \
  bash hack/vsi/bootstrap-hub.sh                                  # ~10 min; prints the Argo CD URL
set -a; source "$HUB_STATE/hub.env"; set +a                       # ARGOCD_URL, ARGOCD_ADMIN_PASSWORD, HUB_FIP, key
GIT_DEPLOY_KEY=~/.ssh/argocd-deploy-key WORKSPACE=sm-cli \
  bash hack/vsi/apply-hub.sh                                      # health check, AppProject, repo key, bnk-secrets, Application
ssh -i "$HUB_SSH_KEY_FILE" ubuntu@$HUB_FIP argocd --core app sync bnk-sm-cli
bash hack/vsi/unbootstrap-hub.sh --yes                            # after deleting the Applications
```

The k3s API is never exposed — `apply-hub.sh` and the sync run over ssh; the Argo CD UI is on `https://<floating-ip>:30443` (user `admin`, initial password in `hub.env`). Register the deploy key on the repository first: `gh repo deploy-key add ~/.ssh/argocd-deploy-key.pub -R <org>/roksbnk-argo-cd`.

### 1. Bootstrap Argo CD

In-target:

```bash
kubectl apply -f bootstrap/openshift/gitops-subscription.yaml       # OpenShift GitOps operator
kubectl apply -f bootstrap/openshift/argocd-cr.yaml                 # bnk-status health check + RBAC
kubectl apply -n openshift-gitops -f bootstrap/appproject-bnk.yaml
```

Hub (upstream Argo CD):

```bash
kubectl apply -f bootstrap/upstream/argocd-cm-health.yaml
kubectl apply -n argocd -f bootstrap/appproject-bnk.yaml
```

### 2. Provide the secrets

Either install External Secrets Operator and adapt `bootstrap/external-secrets/clustersecretstore-ibm.yaml` (`secrets.mode: externalSecret` in the overlay), or create the Secret out of band (`secrets.mode: existing`):

```bash
kubectl -n bnk-<workspace> create secret generic bnk-secrets \
  --from-literal=IBMCLOUD_API_KEY=… \
  --from-literal=ROKSBNKCTL_GENERIC_PASSWORD=…      # mirror password, if any (Secret key roksbnkctl reads)
```

Never commit these values. `secrets.mode: inline` exists for the kind stub only.

### 3. Describe the workspace

Copy `apps/overlays/sm-cli/values.yaml`, pick `sizing.profile`, fill the `config:` block (roksbnkctl's `config.yaml`: cluster, gateway, BNK version, COS bucket) and the storage class. Add the overlay to `apps/applicationset-workspaces.yaml` and apply it.

### 4. Sync — that is the "apply this plan?" step

```bash
argocd app sync bnk-<workspace>            # or the UI
kubectl -n bnk-<workspace> get jobs -l roksbnkctl.io/workspace --sort-by=.metadata.creationTimestamp
kubectl -n bnk-<workspace> logs job/bnk-up --all-containers -f
```

A gate failure fails the sync within seconds, leaves the failed Job for inspection, and sets the Application to *Degraded* with the reason. A successful run ends *Synced / Healthy — "BNK deployed"*.

### 5. Tear down

Delete the Application (PreDelete runs `bnk down --auto`, then the resources go; the PVC stays), or set `lifecycle: down` in the overlay and sync to tear BNK down while keeping the Application.

### Day 2

- **Re-sync** is idempotent: `bnk up` re-plans and applies nothing when the workspace is unchanged.
- **Version bump = upgrade, and BNK 2.3/2.4 have no in-place upgrade**: change `config.bnk.manifest_version` and sync; the `bnk-up` hook runs `bnk down` then `bnk up` (`upgrade.strategy: down-then-up`, the default) or the gate refuses and asks for an explicit `lifecycle: down` sync first (`refuse`). Terraform is never asked to change a running BNK in place.
- **Stuck apply**: every hook has `activeDeadlineSeconds` (`timeouts.*`). Terminating the Argo CD operation does not kill the Job; wait for it or delete it, then sync again.
- **One run at a time per workspace**: RWO PVC + Terraform lock, the same rule the Workflows demos had.

---

## Chart values (the ones you will touch)

| Value | Default | Meaning |
|---|---|---|
| `workspace` | `bnk` | roksbnkctl workspace name (`-w`) |
| `namespace` | `bnk-ci` | namespace the hook Jobs run in |
| `lifecycle` | `up` | `up` → Sync hook runs `bnk up`; `down` → `bnk down` |
| `topology` | `in-target` | `in-target` or `hub` |
| `line` | derived from `config.bnk.manifest_version` | `2.3` enables the cwc-guard container |
| `runner.image`, `runner.tag` | runner `v1.55.1` | the roksbnkctl runner image |
| `config.cluster.create` / `config.cluster.name` | — | `cluster up` (hub) vs `cluster register <name>` |
| `registry.mode` | derived from `config.registry` | `adopt` when a mirror is configured; `replicate` to populate it from the pod |
| `preflight.doctor` / `preflight.command` | `true` / `""` | run `doctor`; delegate the gate to a roksbnkctl verb once `bnk preflight` exists |
| `storage.size` / `storage.storageClassName` | `8Gi` / `""` | the workspace PVC |
| `secrets.mode` / `secrets.name` | `existing` / `bnk-secrets` | `existing`, `externalSecret`, `inline` (dev), `none` |
| `config.*` | — | roksbnkctl's `config.yaml` (cluster, gateway, `bnk`, `cos`, `state`, …) → ConfigMap `bnk-config` |
| `preDelete.enabled` | `true` | render the PreDelete hook (Argo CD ≥ 3.3) |
| `teardown.cluster` | `false` | with `cluster.create: true`: also `tgw disconnect` + `cluster down` on delete |
| `timeouts.*` | see values.yaml | `activeDeadlineSeconds` per hook |

`charts/bnk-workspace/values.yaml` documents everything else.

---

## Verified on kind

```bash
export REPO_MOUNT=$HOME/.cache/roksbnk-argo-cd/kind-repo   # a Linux-filesystem directory
make kind-up        # kind + Argo CD + smart-HTTP git server + stub runner + health check + AppProject
make kind-demo      # publish HEAD, create the Application, sync, wait, print hooks + status
hack/kind/demo.sh delete
make kind-down
```

| Scenario | Result |
|---|---|
| 1 · `bnk up` | init → cluster → preflight → `bnk-up` → PostSync; **Synced / Healthy — "BNK deployed"** |
| 2a · registry mirror incomplete | gate fails at wave −1; **no `bnk-up` Job created**; SyncFail; **Degraded** with the reason |
| 2b · apply fails inside `bnk up` | `bnk-up` Failed; **Degraded — "bnk up exited with status 1"** |
| 3 · `lifecycle: down` | `bnk-down` → PostSync; **Healthy — "BNK torn down"** |
| 4 · delete the Application | PreDelete ran `bnk down` (events + PVC state); resources gone in ~12 s; **PVC retained** |

Failure knobs for the stub live in `apps/overlays/kind-stub/values.yaml`: `STUB_FAIL_GUARD`, `STUB_FAIL_APPLY`, `STUB_MIRROR_MISSING` (with `registry.mode: adopt`).

Design points that matter on a real cluster: gates are Sync-phase hooks (PreSync runs before the substrate exists); the PVC shares the first hook's wave because `WaitForFirstConsumer` classes only bind once a pod mounts the claim and Argo CD waits for wave health; the status ConfigMap is never Degraded on a successful run because a Degraded resource at the end of the Sync phase fails the operation; PreDelete hook Jobs are removed with the Application, so `bnk down` logs are captured separately.

---

## Development

```bash
make lint             # helm lint every overlay (+ lifecycle=down, line=2.3)
make template         # render into .rendered/
make validate         # kubeconform: Kubernetes + Argo CD + External Secrets schemas
make bootstrap-render # re-embed bootstrap/health/bnk-status.lua into the Argo CD wiring files
```

Tooling: helm, kubectl, kind, kubeconform, argocd CLI, docker, python3.

## Roadmap

Tracked in `EVALUATION.md` §8–9: a `bnk preflight` verb in roksbnkctl (the current gate replicates only the workspace-file guards), env overrides for COS remote state, private-endpoint support for in-target disconnected runs, publishing `flp-status`, and — as the "true GitOps" evolution — a `BNKDeployment` CRD with a `roksbnk-operator` so Argo CD syncs one resource and its health is the controller's status.

## License

MIT, following roksbnkctl.
