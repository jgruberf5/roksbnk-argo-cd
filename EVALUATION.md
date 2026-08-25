# Evaluation: `roksbnkctl bnk up` driven purely by Argo CD declarations

**Date:** 2026-08-25 · **Basis:** roksbnkctl v1.54.0 (`/mnt/d/project/roksbnkctl`, commit `101c20a`) · **Status:** discovery / feasibility — input to the book and demo plan.

---

## 1. Executive summary

**Verdict: feasible, and most of it is already built.** The customer can get `bnk up` — with every guard and check roksbnkctl runs today — from a Git repo synced by Argo CD, with **no new container image required for a first working version**. The reason is structural: every guard and every step of `bnk up` is already exercised in-cluster by the Argo *Workflows* demos through the `ghcr.io/jgruberf5/roksbnkctl-tools-runner` image, and everything those workflows need at runtime (namespace, PVC, ServiceAccount, RBAC, ConfigMap, Secret) is an ordinary manifest. What Argo Workflows contributed — ordered imperative steps with logs, parameter gating, a sidecar, and a run history — maps onto Argo CD's **sync phases (PreSync/Sync/PostSync/SyncFail/PreDelete) + sync waves + Job hooks + Lua health checks**.

**What "Argo CD only" cannot change:** `bnk up` is Terraform behind `--auto`, and the Terraform graph (a) mints its cluster credentials from the **IBM API key** (`data.ibm_container_cluster_config`; no kubeconfig input exists), (b) creates IBM-side objects (IAM trusted profile + policies, COS reads), and (c) shells back into `roksbnkctl tfx` for COS downloads, FAR-key extraction, OCI chart pulls, readiness waits and patches. Around the apply, Go code runs four cluster-facing guards that are inherently procedural (unowned-install probe, registry-CA DaemonSet + reachability probe, admission-policy sweep goroutine, Gateway-API bundle SSA). None of that is expressible as a Kubernetes object that Argo CD can diff. **So "Argo CD only" has to mean: Argo CD is the sole orchestrator and source of truth, and the imperative core runs inside Argo CD-managed hook Jobs.** That is a legitimate, well-trodden Argo CD pattern (the same way DB migrations are run), and it is what this evaluation recommends.

**Recommended path (three phases):**

| Phase | What | New containers | Code changes to roksbnkctl | Rough effort* |
|---|---|---|---|---|
| **0 — Spike** | One `Application` on OpenShift GitOps in an existing connected ROKS cluster: Sync-phase gates at negative waves → `bnk up --auto` at wave 0 → PostSync `bnk status --json` | none (runner as-is) | none | 1 week |
| **1 — Productise** | Repo layout, AppProject + RBAC, secrets via External Secrets Operator, Lua health, PreDelete teardown, disconnected/hub variant, ApplicationSet fleet, book chapters + recorded demos | none (+ publish `flp-status`) | small: env for remote state, cwc-guard sentinel, status ConfigMap writer, exit-code classes | 4–6 weeks |
| **2 — Operator (optional)** | `BNKDeployment` CRD + `roksbnk-operator` so Argo CD syncs one CR and the controller owns the lifecycle; Argo CD health reads CR status | **1**: `roksbnk-operator` (FROM runner) | large: reconciler over `internal/orchestration`; private-endpoint support | 8–12 weeks |

\* single experienced engineer, excluding customer review cycles. Phase 1 is the deliverable the book and demos should target; Phase 2 is the "true GitOps" evolution to offer the customer as a roadmap.

---

## 2. What `bnk up` actually does today

Source: `internal/cli/bnk_phase.go`, `internal/orchestration/lifecycle.go` (`RunTrialUp` → `prepareBNKUp`), Terraform under `terraform/`. Legend: **TF** Terraform provider resource · **IBM** Go → IBM Cloud API · **K8s** Go → cluster API (client-go) · **File** local workspace state · **Prompt** interactive confirmation.

| # | Step | Kind | Notes for Argo CD |
|---|---|---|---|
| 1 | Resolve workspace (`config.yaml`, `ROKSBNKCTL_HOME`) | File | Built from `ROKSBNKCTL_*` env by `init --non-interactive --override-from-env` (`internal/cli/seedinput.go:66`) → a ConfigMap |
| 2 | Append mirror CA to trust bundle (`registry-mirror.json` → `SSL_CERT_FILE`) | File | inside runner |
| 3 | `DetectShape` on `state/terraform.tfstate` + `state-cluster/terraform.tfstate` | File | needs persisted workspace (PVC or COS remote state) |
| 4 | Empty workspace → offer `cluster up` bootstrap | Prompt → TF/IBM | in-target model: cluster already exists → `cluster register` instead |
| 5 | Resolve IBM API key (env → keychain → `api_key_b64` → prompt) | File/Prompt | **must** be env in a pod (`internal/cred/resolver.go:225`) → Secret |
| 6 | `tf.Open`: extract embedded HCL, write backend override (local or COS-S3), plugin cache | File | runner has terraform 1.10.5 |
| 7 | **Guard** `guardRegistryMirror` — `registry-mirror.json` present, complete, `missing_count==0`, matches configured target | File | produced by a prior `registry adopt`/`replicate` Job |
| 8 | Render `terraform.tfvars`, `bnk-phase-override.tfvars`, `bnk-flp-override.tfvars` (FLP handoff **required** in `f5licenseproxy` mode); `terraform init` | File | FLP handoff = two env vars from a Secret |
| 9 | **Guard** `guardSupportedCombination` — line (2.3/2.4) × cluster `network_mode` vs embedded support matrix | File | |
| 10 | **Guard** `guardCreateTimeSettings` — network-mode drift, namespace-topology change, 2.3↔2.4 line flip refused | File | reads applied-tfvars snapshot |
| 11 | **Guard** `guardUnownedBNKInstall` — empty state but FLO pods already in cluster → refuse | IBM + K8s | admin kubeconfig fetched from IBM API |
| 12 | `terraform plan` | TF | |
| 13 | "Apply this plan?" | Prompt | `--auto`; **maps to Argo CD manual sync / sync window** |
| 14 | **Guard** `checkMirrorCredentials` | File | |
| 15 | **Guard** `ensureRegistryCATrust` — privileged DaemonSet writes mirror CA on every node and TCP-probes registry (+FLP); fails if any node can't reach | K8s | needs `privileged` SCC binding (already coded) |
| 16 | Admission-policy sweep goroutine (deletes `openshift-ingress-operator-gatewayapi-crd-admission` VAP/binding/VWC every 5 s) + Gateway API bundle SSA (2.4 mTLS) | K8s | runs for the whole apply — must be co-located with the apply |
| 17 | `terraform apply -auto-approve` with transient-error retry (5×90 s) | TF + `tfx` local-exec | 15-minute readiness gates inside (`CNEControllerAvailable`, `License.status.state=Active`) |
| 18 | Write `terraform.applied.tfvars` snapshot | File | |
| 19 | Fetch admin kubeconfig, write jumphost targets | IBM/File | best-effort |
| 20 | Exit 0 / 1 (all guards → exit 1, reason on stderr; `internal/exitcode`) | | SyncFail hook can capture logs |

What the apply installs into the cluster (Terraform `modules/{cert_manager,flo,cne_instance,license}`): cert-manager Helm (`v1.17.3`), namespaces `f5-bnk`/`f5-utils`, pull secrets, cert-manager issuer chain, NADs, **FLO Helm** (chart pulled by `tfx` from FAR/mirror, `containerPlatform: IBM`), `CNEManifest`, CIS Helm (2.3), SCC ClusterRoleBindings, node-labeler Job (2.3), `CNEInstance`, `F5SPKVlan`s (2.3), `License`, CWC restart (FLP mode) — plus IBM IAM trusted profile/link/policies for the CNE controller.

`bnk down` mirrors this: shape check, teardown-webhook sweep, replay of applied tfvars, `terraform destroy` with retry, finalizer stripping, 34 named license secrets swept.

**Key facts that shape the design**

* No `-target`, no kubeconfig variable: the IBM API key is the only credential path (`terraform/modules/*/providers.tf`). An in-cluster ServiceAccount cannot replace it.
* Guards are mostly **consistency checks on workspace files** (`cluster-outputs.json`, `registry-mirror.json`, `flp-outputs.json`, tfstate, applied tfvars). The workspace directory *is* the state contract — the Workflows demos keep it on an RWO PVC (`00-prereqs.yaml`). COS remote state moves only `terraform.tfstate`, not the JSON handoffs.
* roksbnkctl **never uses the pod's SA** against ROKS — `rest.InClusterConfig()` exists behind an unused sentinel (`internal/k8s/client.go:22`). Fine for Argo CD: the hook Job carries the API key.
* The code already anticipates running as a pod *inside* the target cluster (`internal/orchestration/gateway_api_bundle.go:165`, `internal/bnkbom/gateway_api.go:19`).
* IBM/COS endpoints are hard-coded public (`internal/ibm/cluster_config.go:24`, `internal/cos/client.go:20,273`) → a pod in a **disconnected** ROKS cluster cannot run `bnk up` today.
* No lifecycle verb emits JSON; `bnk status --json` does (`internal/cli/phase_status.go`). **There is no standalone BNK preflight**: `roksbnkctl plan` is the legacy composite path (`RunPlan` → `writeAndInit`, `internal/orchestration/lifecycle.go:407-422`) — it neither writes the bnk-phase override nor runs the BNK guards, so it cannot gate a split workspace. A `bnk preflight` verb (Phase 1, size M) is the fix; until then the chart replicates the workspace-file guards in shell.

---

## 3. What Argo CD gives us (and what it does not)

Verified against current docs (Argo CD 3.3 is the latest stable; OpenShift GitOps is Red Hat's supported distribution on ROKS):

| Capability | Use here |
|---|---|
| **Resource hooks** `PreSync` → `Sync` → `PostSync`; `SyncFail` on failure; `PreDelete` (3.3+) / `PostDelete` on Application deletion | Guards = Sync-phase Jobs at negative waves (PreSync runs before the substrate exists); `bnk up` = Sync Job at wave 0; status = PostSync Job; diagnostics = SyncFail Job; `bnk down` = PreDelete Job |
| A failed hook Job fails the sync; later phases don't run; `SyncFail` hooks run | Guard failure gates the 45–90 min apply exactly like a Workflow step failure |
| `hook-delete-policy: BeforeHookCreation` (default) / `HookSucceeded` / `HookFailed` | keep failed Jobs for log inspection, replace on next sync |
| **Sync waves** order resources and hooks within a phase; Argo waits for health between waves (2 s default gap) | `cluster register` (wave −3) → `registry adopt` (−2) → `plan` (−1) → `bnk up` (0) |
| **Custom health** (Lua in `argocd-cm` / OpenShift GitOps `ArgoCD.spec.resourceHealthChecks`) for any Kind incl. CRDs | health of the status object; in Phase 2, of `BNKDeployment`; Argo already has a built-in Job health |
| Sync options `Prune=false`, `Delete=false`, `Replace`, `Force`, `ApplyOutOfSyncOnly`, `FailOnSharedResource`, `CreateNamespace` | PVC protected from prune/delete; Jobs recreated |
| Manual vs automated sync, `syncPolicy.retry`, AppProject **sync windows**, RBAC on `sync` | replaces the "Apply this plan?" prompt with an auditable approval; retry limit 0 for the apply |
| ApplicationSet generators | one Application per workspace/cluster (connected, disconnected, existing) |
| Multi-cluster via cluster Secrets | hub topology for disconnected sites |

**Not provided:** step-level logs/history UI (only Job pod logs), parameters at sync time (everything comes from Git), sidecar lifecycle (a Job's containers are independent), hook timeouts (use `activeDeadlineSeconds`), and — fundamentally — no way to reconcile IBM Cloud resources or run Terraform natively. Third-party options for the last point were assessed and rejected as the primary path:

* **Crossplane `provider-ibm-cloud`** — archived 2025-10-14, read-only. Not viable.
* **tofu-controller** (v0.16.5, Aug 2026) — actively maintained but requires Flux source-controller; Argo CD integration only via "Flux Subsystem for Argo" (tech preview). Adds a second GitOps engine — contradicts "Argo CD only".
* **GalleyBytes terraform-operator** (v0.17.1, May 2026) — Argo CD-aware (documented Lua health for `tf.galleybytes.com/Terraform`), could run the embedded HCL with the runner image as its task image. Viable as an *alternative* Phase 2, but it still needs the Go-side guards run around it and adds a third-party operator to the customer's estate. Kept as an option, not recommended.
* **IBM Cloud Operator / IAM operator** — CRD-based provisioning of catalog services; does not cover ROKS clusters, VPC or the BNK supply chain.

---

## 4. Topology: where Argo CD runs

| Model | Description | Fits | Caveats |
|---|---|---|---|
| **A. In-target (recommended for connected clusters)** | OpenShift GitOps operator on the ROKS cluster that receives BNK. Hook Jobs run in the same cluster; roksbnkctl inside them still authenticates to IBM with the API key and fetches the admin kubeconfig. | "Argo CD declarations into the ROKS cluster" — literally the customer's ask; Red Hat-supported; OpenShift OAuth login | cluster must pre-exist (`cluster register` path; `cluster up/down` cannot run from inside the cluster they create/destroy); the runner pod modifies the cluster it runs in (already the case in the code's assumptions); egress to IBM APIs, FAR/mirror, `releases.hashicorp.com` unless plugin cache is pre-seeded on the PVC |
| **B. Hub** | Argo CD on a management cluster (the services-VPC k3s VSI the Workflows demos already build, or a small management ROKS). Driver Application destination = hub (`in-cluster`), hook Jobs reach ROKS API + Harbor over the Transit Gateway; native manifests (Phase 2 / gateway CRs) target the spoke via an Argo CD cluster Secret. | **required for disconnected clusters** (pods there cannot reach public IBM endpoints) and for `cluster up` from Git | needs a cluster Secret for the spoke (today roksbnkctl fetches admin kubeconfigs from IBM; a small `cluster register --argocd-cluster-secret` helper would close this) |
| **C. In-target + private endpoints** | As A, in a disconnected cluster, with roksbnkctl and the IBM provider using private service endpoints | ideal end state | requires Go changes (§8) and provider `IBMCLOUD_VISIBILITY=private`; untested |

Recommendation: build the demos on **A** (existing connected cluster, OpenShift GitOps) and **B** (disconnected, hub = upstream Argo CD on the existing k3s VSI bootstrap, later a management ROKS). Both share the same Git repo layout; only the `Application.spec.destination` and a values overlay differ.

---

## 5. Candidate designs

### Design 1 — Hook-driven runner (recommended, Phases 0–1)

One `Application` per workspace. Regular resources (synced and diffed by Argo CD): Namespace `bnk-ci`, PVC `bnk-work` (`Prune=false`, `Delete=false`), ServiceAccount + Role/RoleBinding, ConfigMap `bnk-env` (all `ROKSBNKCTL_*` non-secret settings, or a committed `config.yaml`), `ExternalSecret` → `bnk-secrets` (IBM API key, mirror password, BIG-IP/GTM passwords, FLP handoff), optional `flp-status` Deployment, optional ops-pod stack. Hook Jobs (runner image, `envFrom` ConfigMap+Secret, PVC at `/work`, `ROKSBNKCTL_HOME=/work/.roksbnkctl`, `activeDeadlineSeconds` set):

| Hook | Wave | Command | Purpose |
|---|---|---|---|
| (regular) | −10 | Namespace, ServiceAccount, Role/RoleBinding, ConfigMap `bnk-env`, Secret | substrate |
| (regular) | −4 | PVC `bnk-work` | same wave as the first hook: `WaitForFirstConsumer` classes bind only when a pod mounts the claim, and Argo CD will not leave a wave while a resource is Progressing |
| Sync | −4 | `roksbnkctl init -w $WS --non-interactive --override-from-env && roksbnkctl doctor` | rebuild workspace from Git-declared env; host/tool checks |
| Sync | −3 | `cluster register $NAME --registry-cos-name …` (in-target) / `cluster up --auto` (hub) | produces `cluster-outputs.json` |
| Sync | −2 | `registry adopt` (disconnected) / `registry replicate --target generic` (hub, FAR-reachable) | produces `registry-mirror.json`; satisfies `guardRegistryMirror` |
| Sync | −1 | shell replica of the workspace-file guards (mirror record, FLP hand-off, line change) — `bnk preflight` once it exists | fast fail before the long apply; `bnk up` still re-runs every guard itself |
| Sync | 0 | `bnk up --auto` + `cwc-guard` container (BNK 2.3) | the apply, admission sweep, CA DaemonSet, Gateway bundle all happen here as today |
| (regular) | 0 | ConfigMap `bnk-status` (data owned by the hooks; `ignoreDifferences` + `RespectIgnoreDifferences`) | Lua health → Application health |
| PostSync | 0 | `bnk status --json` → merge-patched into `bnk-status` | machine-readable outcome |
| SyncFail | 0 | records the failed hooks + reason into `bnk-status` | Application Degraded with the reason |
| PreDelete (Argo CD ≥ 3.3) | 0 | `bnk down --auto` | teardown when the Application is deleted; PVC kept via `Delete=false` |

The gates are **Sync-phase hooks at negative waves, not PreSync hooks**: PreSync runs before any regular resource is applied, so a PreSync Job has no PVC, ConfigMap, Secret or ServiceAccount to start with. Within the Sync phase, Argo CD interleaves hooks and resources by wave and waits for each wave's health, which gives exactly the ordering above.

Behavioural mapping of today's UX: the "Apply this plan?" prompt becomes **manual sync** on the Application (RBAC-controlled, audited, optionally restricted by an AppProject sync window); `roksbnkctl bnk status` becomes Application health; `bnk down` becomes deleting the Application (or, before 3.3, flipping a `lifecycle: down` value in Git that switches the Sync hook to `bnk down --auto`).

Strengths: zero new images, zero Go changes to demo, single source of truth (Git), same guards byte-for-byte, works with OpenShift GitOps today. Weaknesses: hooks re-run on every sync (harmless — `plan` no-op, `apply` no-op, but ~5 minutes of churn), Argo CD's diff view says nothing about BNK itself, one Application = one workspace = one runner at a time (RWO PVC + terraform lock — same constraint the Workflows had).

### Design 2 — Native decomposition into Argo CD manifests

Re-express the cluster-side content of the bnk phase as Helm/Kustomize managed by Argo CD in waves: cert-manager (Helm from `charts.jetstack.io`), namespaces/pull secrets/issuers/NADs, **FLO Helm from `oci://repo.f5.com` or the mirror** (Argo CD repo credentials with `_json_key_base64`), `CNEManifest` (rendered offline from the manifest chart), SCC bindings, `CNEInstance`, `F5SPKVlan`, `License` — with Lua health checks on `CNEInstance` (`CNEControllerAvailable`/`Available`) and `License` (`status.state=Active`). A residual Job/controller still has to do: IAM trusted profile + policies, COS-sourced FAR key/JWT (or pre-stage them as Secrets), admission-policy sweep during CRD install, registry-CA DaemonSet, CWC restart on CA change, and `bnk down`'s finalizer/webhook/secret cleanup.

Strengths: true GitOps fidelity; BNK objects visible and diffable in the Argo CD UI. Weaknesses: **duplicates the Terraform** (two implementations of the BNK install to keep in step with every BNK/roksbnkctl release), loses `roksbnkctl`'s tested guard logic unless re-implemented, and the imperative residue still needs a Job or operator. Not recommended as the primary path, but two slices are cheap wins and should be in the book: (i) `resources.cert_manager.create: false` and let Argo CD own cert-manager natively; (ii) the **gateway phase** (pure `kubectl_manifest` SSA today — `GatewayClass`, `Infra`, `GatewaySettings`, `Gateway`, `HTTPRoute`, …) can be Argo CD-native immediately, with Lua health on the Gateway conditions.

### Design 3 — Terraform-in-cluster operator

`Terraform` CR (GalleyBytes terraform-operator) pointing at the embedded HCL published as a Git/OCI source, task image = runner (so `tfx` local-execs work), Argo CD syncs the CR and reads its status via the documented Lua health. Still needs the Go-side guards as pre/post tasks and the admission sweep concurrently with the apply (the operator's task hooks could run them). Adds a third-party controller. Keep as a fallback if the customer objects to Jobs as hooks.

### Design 1+ — CRD + operator (Phase 2 evolution of Design 1)

Publish a `BNKDeployment` CRD (spec = today's `config.yaml` schema; status = phase, conditions, outputs of `bnk status --json`). A `roksbnk-operator` (new `cmd/`, image `FROM` the runner) reconciles it by calling `internal/orchestration` directly, with the preflight guards as CR conditions (`RegistryMirrorReady`, `SupportedCombination`, `ClusterUnowned`, `RegistryReachable`, `Planned`, `Applied`, `LicenseActive`). Argo CD syncs one small CR; deletion → finalizer → `bnk down`. This makes Argo CD's health and diff meaningful, removes the PVC coupling (operator holds state, or COS remote state), and gives the customer a real declarative API. It is the natural "book part 3".

---

## 6. Guard-by-guard mapping (Design 1)

| roksbnkctl guard / check | Argo CD mechanism | Fidelity |
|---|---|---|
| terraform/helm on PATH, tool versions (`doctor`) | PreSync Job (wave −4); image pins terraform 1.10.5 | same |
| API key resolvable / IAM verify | ExternalSecret → Secret; `doctor` in PreSync | same, no prompt |
| Workspace initialised, required fields (`region`, `resource_group`, `prefix`) | `init --non-interactive` in PreSync fails fast; Git review of ConfigMap | same |
| `guardRegistryMirror` (record present/complete/matches) | `registry adopt`/`replicate` PreSync Job (wave −2); file check in the preflight gate (wave −1); re-run by `bnk up` | same |
| `guardSupportedCombination`, `guardCreateTimeSettings` | line-change check in the preflight gate; full check inside `bnk up` | same |
| `guardUnownedBNKInstall` | inside `bnk up` (needs the admin kubeconfig) — moves to `bnk preflight` when that verb exists | same |
| `checkMirrorCredentials` | inside `bnk up` Sync Job | same |
| `ensureRegistryCATrust` (DaemonSet + node reachability) | inside `bnk up` Sync Job; needs SCC-privileged binding — Argo CD can also own the DaemonSet stack natively as a wave −1 resource | same |
| Admission-policy sweep / Gateway API bundle | inside `bnk up` Sync Job (must be concurrent with apply) | same |
| "Apply this plan?" confirmation | manual sync + AppProject sync window + RBAC `applications, sync` | **better** (audited) |
| Transient retry 5×90 s | inside `bnk up`; Argo `syncPolicy.retry.limit: 0` so Argo does not add its own | same |
| cwc-guard sidecar (2.3) | second container in the Sync Job; shared emptyDir sentinel so it exits when `bnk up` exits | same (small script change) |
| Readiness gates (`tfx wait` 15 min ×2) | inside apply; Job `activeDeadlineSeconds: 7200` bounds a hang | same + bounded |
| `bnk status` | PostSync Job → `bnk-status` ConfigMap; Lua health → Application Healthy/Degraded | **better** (continuous) |
| `bnk down` refusals (gateway state present, uninitialised workspace) | PreDelete Job exit 1 → Application deletion blocks | same |
| Concurrency (one run per workspace) | RWO PVC + terraform lock + Argo serialises hooks per Application | same |
| Chokepoint (`--var-file` absolute paths) | n/a — paths are fixed in the Job spec | n/a |

---

## 7. Proposed Git repository layout (this project)

```
roksbnk-argo-cd/
├── bootstrap/                      # one-time, per cluster
│   ├── openshift-gitops-subscription.yaml   # in-target model
│   ├── argocd-cr.yaml              # ArgoCD CR: resourceHealthChecks (Lua), RBAC, sync windows
│   ├── appproject-bnk.yaml         # destinations, source repos, clusterResourceWhitelist (CRDs, CRBs, SCC bindings, DaemonSet ns)
│   └── external-secrets/           # ESO ClusterSecretStore → IBM Secrets Manager (or Vault)
├── charts/bnk-workspace/           # Helm chart rendering one workspace
│   ├── templates/{namespace,pvc,sa-rbac,configmap-env,externalsecret}.yaml
│   ├── templates/hooks/{00-init-doctor,10-cluster,20-registry,30-plan,40-bnk-up,50-status,90-syncfail,95-predelete}.yaml
│   └── values.yaml                 # runnerImage, workspace, ROKSBNKCTL_* map, topology: in-target|hub, line: 2.3|2.4
├── apps/                           # Applications / ApplicationSet
│   ├── applicationset-workspaces.yaml   # list generator: bnkconn (connected, in-target), bnkdisco (hub), …
│   └── overlays/{bnkconn,bnkdisco,existing-cluster}/values.yaml
├── native/                         # Design-2 slices Argo CD owns directly
│   ├── cert-manager/               # Helm, wave −5, when resources.cert_manager.create=false
│   ├── gateway/                    # gateway-phase CRs, Lua health on Gateway conditions
│   └── flp-status/                 # deploy/flp-status/k8s.yaml de-placeholdered
└── docs/                           # book chapters + demo scripts (see §10)
```

Sketch of the Sync hook (values omitted):

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: bnk-up
  annotations:
    argocd.argoproj.io/hook: Sync
    argocd.argoproj.io/sync-wave: "0"
    argocd.argoproj.io/hook-delete-policy: BeforeHookCreation
spec:
  backoffLimit: 0
  activeDeadlineSeconds: 7200
  template:
    spec:
      serviceAccountName: bnk-runner
      restartPolicy: Never
      securityContext: {runAsNonRoot: true, seccompProfile: {type: RuntimeDefault}}
      volumes:
        - {name: work, persistentVolumeClaim: {claimName: bnk-work}}
        - {name: signal, emptyDir: {}}
      containers:
        - name: bnk-up
          image: ghcr.io/jgruberf5/roksbnkctl-tools-runner:v1.54.0
          command: [sh, -ec]
          args: ["trap 'touch /signal/done' EXIT; roksbnkctl -w $WS bnk up --auto"]
          envFrom: [{configMapRef: {name: bnk-env}}, {secretRef: {name: bnk-secrets}}]
          env: [{name: ROKSBNKCTL_HOME, value: /work/.roksbnkctl}, {name: HOME, value: /home/runner}]
          volumeMounts: [{name: work, mountPath: /work}, {name: signal, mountPath: /signal}]
        - name: cwc-guard        # BNK 2.3 only
          image: ghcr.io/jgruberf5/roksbnkctl-tools-runner:v1.54.0
          command: [sh, -ec]
          args: ["until [ -f /signal/done ]; do <existing cwc-guard loop body>; sleep 10; done"]
          volumeMounts: [{name: work, mountPath: /work}, {name: signal, mountPath: /signal}]
```

---

## 8. Containers and code changes

### Containers

| Image | Status | Needed for | Work |
|---|---|---|---|
| `ghcr.io/jgruberf5/roksbnkctl-tools-runner` | exists (ubuntu 22.04, uid 1000/gid 0, restricted-v2 clean; terraform 1.10.5, helm, kubectl/oc, ibmcloud, iperf3, h2load) | every hook Job | none for Phase 0/1. Optional: pre-seed terraform plugin cache in the image (removes `releases.hashicorp.com` egress); UBI9 base if the customer mandates Red Hat bases; publish a digest-pinned tag |
| `flp-status` | exists but **not in the CI publish matrix**, `USER 0` | FLP visibility in the UI, `native/flp-status` | add to `tools-images.yml`, run non-root, publish |
| `roksbnk-operator` (**new**, Phase 2) | — | `BNKDeployment` CRD reconciler | new `cmd/roksbnk-operator`, controller-runtime, `FROM` runner (needs terraform+helm), OLM bundle or plain Deployment synced by Argo CD |
| External Secrets Operator (third-party, OperatorHub) | — | `bnk-secrets` from IBM Secrets Manager / Vault / SealedSecrets | configuration only |
| OpenShift GitOps operator (Red Hat) / upstream Argo CD ≥ 3.3 on the hub | — | Argo CD itself | check the GitOps channel ships Argo CD ≥ 3.3 if PreDelete hooks are used; otherwise use the `lifecycle: down` value flip |
| `terraform-operator` (third-party) | — | only if Design 3 is chosen | n/a |

No `ops` image (`tools-ibmcloud`) is needed — it lacks terraform/helm.

### roksbnkctl changes (all optional for Phase 0; recommended for Phase 1)

| Change | Size | Why |
|---|---|---|
| `ROKSBNKCTL_STATE_BACKEND=s3` + `ROKSBNKCTL_STATE_S3_*` env overrides (`internal/config/envoverride.go` has no `state:` mapping) | S | lets the env-built workspace use COS remote state; the PVC then holds only JSON handoffs |
| `bnk status --json` (and `plan`) write a status ConfigMap (`--status-configmap ns/name`) — or keep it in the hook shell | S | Argo CD health without shell glue |
| `bnk status --json` should report `deployed:false` when the state file holds zero resources (today it reports `true` right after `bnk down`; the chart cross-checks the tfstate) | S | correct health after a teardown without shell workarounds |
| `bnk preflight` verb = `prepareBNKUp` up to and including `terraform plan` (with the bnk-phase override), categorised exit codes (PRD 17) | M | **needed**: `roksbnkctl plan` is the legacy composite path and cannot gate a split workspace; the chart's shell gate only covers the file guards |
| cwc-guard folded into `bnk up` (2.3) or documented sentinel pattern | S | one container, no sidecar lifecycle problem |
| `cluster register --argocd-cluster-secret <ns/name>` writes an Argo CD cluster Secret from the fetched admin config (with token refresh via `kubeconfig_refresh.go`) | M | hub model for native manifests |
| Private-endpoint support (`IBMCLOUD_VISIBILITY=private` honoured by `internal/ibm`, `internal/cos`, backend endpoint, and passed to the provider) | L | in-target disconnected runs (Topology C) |
| Wire the `in-cluster` sentinel for cluster-side guards when `KUBERNETES_SERVICE_HOST` is set and no API key is present | M | only if the customer wants API-key-less cluster-side steps; not needed while terraform requires the key anyway |
| `BNKDeployment` CRD + `roksbnk-operator` | L | Phase 2 |

---

## 9. Risks and open questions

1. **Hook re-execution on every sync.** Any Git change to the workspace (even a comment) re-runs all hooks: `plan` (~2–5 min) then `bnk up` (no-op apply, still minutes). Mitigation: manual sync; `ApplyOutOfSyncOnly` does not affect hooks; Phase 2 CRD removes this entirely.
2. **Argo CD version on OpenShift GitOps.** `PreDelete` hooks arrived in Argo CD 3.3 — confirm the customer's GitOps channel; fall back to the `lifecycle: down` flip.
3. **Long-running Sync operation.** 45–90 min with the Application in `Syncing`; a controller restart resumes waiting on the Job, but operators must not "terminate" the sync mid-apply (it does not kill the Job; the terraform lock then blocks the next run until the Job ends). Document `activeDeadlineSeconds` and how to recover (`roksbnkctl state unlock` equivalents).
4. **State persistence contract.** RWO PVC ⇒ hook Jobs must schedule on one node; on ROKS use `ibmc-vpc-block-*` (RWO) — fine. Deleting the Application must never delete the PVC (`Delete=false`, `Prune=false`); back it up or move tfstate to COS.
5. **Secrets.** Today the demo driver creates `bnk-secrets` imperatively; Git must never hold the API key, FAR key, JWT. ESO with IBM Secrets Manager is the natural fit; the FAR tarball/JWT stay in COS (unchanged).
6. **Self-modification.** In-target hook Jobs delete admission policies and run a privileged DaemonSet on the cluster hosting Argo CD. AppProject `clusterResourceWhitelist` and a dedicated SA keep Argo CD's own permissions narrow while the Job carries the admin kubeconfig it minted — make this explicit to the customer's security team.
7. **Disconnected in-target** is blocked by public endpoints in Go (Topology C, size L). The hub model works today and is what the existing demos already do.
8. **Cluster lifecycle from Git.** `cluster up/down` only makes sense on a hub. If the customer expects "the whole thing from Git", the hub is mandatory.
9. **Two sources of truth if Design 2 slices are adopted** (cert-manager, gateway) — keep the `resources.*.create: false` flags aligned in `bnk-env`.

---

## 9a. Verified on kind (2026-08-25)

The scaffold in this repository (`charts/bnk-workspace`, `bootstrap/`, `apps/`) was exercised against **Argo CD v3.5.1 on kind** with a stub runner image that reproduces roksbnkctl's verbs, guards, exit codes and workspace files (`hack/stub-runner`). Transcripts: `docs/verification/`.

| Scenario | Result |
|---|---|
| `bnk up` | init → cluster → preflight → `bnk-up` → PostSync; Application **Synced / Healthy — "BNK deployed"** |
| registry mirror incomplete | gate fails at wave −1, **no `bnk-up` Job created**, SyncFail runs, **Degraded** with the reason |
| apply fails inside `bnk up` | `bnk-up` Failed, **Degraded — "bnk up exited with status 1"** |
| `lifecycle: down` | `bnk-down` → PostSync; **Healthy — "BNK torn down"** |
| delete the Application | PreDelete ran `bnk down` (events + PVC state), resources removed in ~12 s, **PVC retained** |

What the harness caught (all apply to a real cluster): (1) gates must be Sync-phase hooks (see §5); (2) a `WaitForFirstConsumer` PVC in its own wave deadlocks the sync — `argocd.argoproj.io/ignore-healthcheck` fixes Application health but not wave gating, so the claim shares the first hook's wave; (3) a Degraded resource at the end of the Sync phase fails the operation and skips PostSync — the status object must never be Degraded on a successful run (a `jq '.deployed // "unknown"'` that turned `false` into "unknown" did exactly that); (4) Argo CD deletes the PreDelete hook Job with the Application, so `bnk down` logs must be captured elsewhere; (5) the ApplicationSet/Application need `ignoreDifferences` on `bnk-status` `/data` plus `RespectIgnoreDifferences=true` or Argo CD overwrites the hooks' status on every sync.

## 10. What the book and demos should cover (proposal)

Book part: *"BNK on ROKS with Argo CD"* — chapters: (1) Argo CD concepts used (phases, waves, hooks, health, sync windows) mapped to the roksbnkctl lifecycle; (2) installing OpenShift GitOps on ROKS and the AppProject/RBAC model; (3) the workspace chart and secrets model (ESO); (4) **Demo A — existing connected cluster, in-target**: sync → watch PreSync gates → apply → Healthy; induce a guard failure (blank COS bucket, mirror record missing, 2.3↔2.4 flip) and show the sync fail *before* the apply; (5) **Demo B — disconnected via hub**: Harbor mirror Job, `registry adopt`, FLP handoff Secret, spoke cluster Secret; (6) **Demo C — fleet**: ApplicationSet over three workspaces; (7) day-2: manifest-version bump in Git, `bnk down` via Application deletion, recovering a locked state; (8) roadmap: `BNKDeployment` CRD / operator; (9) reference: every `ROKSBNKCTL_*` key → values.yaml, Lua health scripts, RBAC tables.

Demo scripts can reuse `scripts/demos/lib/` (recording, masking) and the `bootstrap-*.sh` VSI builders unchanged; the Argo Workflows install line in `argo-vsi-cloud-init.yaml.tmpl` becomes an Argo CD install for the hub demo.

---

## Appendix — evidence index

* `bnk up` flow: `internal/cli/bnk_phase.go:81-112`, `internal/orchestration/lifecycle.go:283-404, 380-402, 962-1017`; guards `lifecycle.go:887-925`, `create_time_guard.go`, `bnk_adopt_guard.go`, `registry_trust.go`, `admission_sweep.go`, `gateway_api_bundle.go`; exit codes `internal/exitcode/exitcode.go`.
* Terraform: `terraform/main.tf`, `terraform/modules/{roks_cluster,cert_manager,flo,cne_instance,license,flp,gateway}`, providers `terraform/versions.tf` (ibm 1.89, kubernetes 3.2, helm 2.17, kubectl 2.4.1); backend `internal/tf/backend.go`; `tfx` verbs `internal/cli/tfx.go`.
* Runner image: `tools/docker/runner/Dockerfile`, `docs/prd/15-RUNNER-IMAGE.md`, `.github/workflows/tools-images.yml`.
* Workflows demos: `scripts/demos/blueprint-workflows-ci-demo/workflows/*.yaml` (`00-prereqs.yaml`, `wf-existing-cluster.yaml` incl. cwc-guard sidecar), `scripts/demos/disconnected-cluster-ci-demo/{argo-vsi-cloud-init.yaml.tmpl,gitops/}`, `book/src/appendix-a-disconnected-roks-cluster.md:763-781`.
* In-cluster surfaces: `internal/exec/k8s_install.yaml` (ops pod), `internal/k8s/client.go:22,163-203` (in-cluster sentinel), `deploy/flp-status/k8s.yaml`, `cmd/flp-status/Dockerfile`.
* Argo CD: resource hooks / sync waves / health / sync options (argo-cd.readthedocs.io, stable), Argo CD 3.3 release notes (PreDelete hooks, RBAC by resource name), OpenShift GitOps usage guide (redhat-developer/gitops-operator), tofu-controller releases (v0.16.5), GalleyBytes terraform-operator Argo CD page (v0.17.1), crossplane-contrib/provider-ibm-cloud (archived 2025-10-14).
