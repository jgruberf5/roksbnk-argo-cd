# Troubleshooting

The design puts every failure in one of two places: a hook Job's logs, and the
`bnk-status` ConfigMap's `message`. Start with the Application's health
message (hover the heart, or open `bnk-status`), then open the Job it names.

```bash
kubectl -n bnk-<ws> get configmap bnk-status -o jsonpath='{.data.message}{"\n"}'
kubectl -n bnk-<ws> get jobs --sort-by=.metadata.creationTimestamp
kubectl -n bnk-<ws> logs job/<the failed one> --all-containers
```

## The sync failed before bnk-up

The Application is **Degraded**, `bnk-syncfail` ran, and `bnk-up` is not in the
tree. The message names the hook:

| Message | Cause | Fix |
|---|---|---|
| `sync failed (hooks: bnk-init)` and the log ends in `✗ ibm cloud auth … Provided API key could not be found` | The key in `bnk-secrets` is wrong — most often a **trailing newline** from a here-string | Recreate the Secret with `printf '%s' "$KEY" \| kubectl create secret … --from-file=IBMCLOUD_API_KEY=/dev/stdin` |
| `bnk-init`: `ibmcloud.region is required` (or `resource_group`, `prefix`) | the required keys are missing from the overlay's `config` | add `config.ibmcloud.region`, `config.ibmcloud.resource_group`, `config.prefix` |
| `bnk-cluster`: cluster not found | `cluster.name` wrong, or the key's account/region differ | check `ibmcloud ks clusters` with the same key |
| `preflight: a registry mirror is configured … but there is no record of it` | `registry.mode: none` in the overlay while `config.registry` names a mirror | set `registry.mode: adopt` (mirror populated elsewhere) or `replicate`, or remove `config.registry` |
| `preflight: registry mirror incomplete: N artifacts missing` | the mirror is short of images | run `registry replicate` (or fix the mirror) and sync |
| `bnk-registry`: `adopt --verify-contents: 1 of 94 artifacts are missing or digest-mismatched` naming `bitnami/kubectl` | the mirror is intact; upstream moved the floating `latest` tag of the node-labeler image after the mirror was populated, so the source digest no longer matches | run `registry replicate` against the mirror (it refreshes the moved image and skips the rest by digest), then sync |
| `preflight: license_mode=f5licenseproxy but no FLP hand-off` | `config.bnk.license_mode: f5licenseproxy` without the proxy's endpoint and root CA | add `config.bnk.flp.external` (`url` + `root_ca_b64`) to the overlay ([Appendix B](appendix-b-private-registry-flp.md)) |
| `preflight: BNK version change X -> Y on an applied workspace: BNK does not support in-place upgrades` | `upgrade.strategy: refuse` and the manifest version changed | set `lifecycle: down`, sync, change the version, set `lifecycle: up`, sync — or use `down-then-up` |
| `preflight: BNK line change 2.3 -> 2.4 is refused` | the manifest version crosses lines on an applied workspace | `lifecycle: down`, sync, then change it |
| `Job was active longer than specified deadline` on `bnk-init` and nothing else ran | the hook could not start — pod events show a missing ServiceAccount or PVC | the chart's waves prevent this; check that nothing renamed `storage.claimName` or `serviceAccount.name` between syncs |

A version bump with `upgrade.strategy: refuse` produces the same shape — the
gate stops the sync and the previous `bnk-up` Job is untouched. With the
default `down-then-up` the same bump is accepted and the `bnk-up` log shows
`bnk down` completing before `bnk up` starts.

This is what a gate failure looks like in the UI (from the kind verification
run, where the mirror was deliberately left incomplete):

```text
GROUP  KIND       NAME           STATUS     HEALTH   HOOK      MESSAGE
batch  Job        bnk-init       Succeeded  Synced   Sync      Reached expected number of succeeded pods
batch  Job        bnk-cluster    Succeeded  Synced   Sync      Reached expected number of succeeded pods
batch  Job        bnk-registry   Succeeded  Synced   Sync      Reached expected number of succeeded pods
batch  Job        bnk-preflight  Failed     Synced   Sync      Job has reached the specified backoff limit
batch  Job        bnk-syncfail   Succeeded  Synced   SyncFail  Reached expected number of succeeded pods
       ConfigMap  bnk-status     Synced     Degraded           preflight: registry mirror incomplete: 3 artifacts missing
```

## bnk-up failed

The message reads `bnk up exited with status 1 — see job/bnk-up logs`. Search
the log from the end:

- **`terraform apply failed after 5 attempts`** — roksbnkctl already retried
  transient errors (webhook not ready, connection refused). The line above it
  is the real error.
- **`cnecontroller_ready` / `license_active` timed out** — the F5 controller
  never reported Available, or the licence never went Active. Check the pods in
  `f5-bnk`/`f5-utils` on the cluster (image pulls from FAR are the usual cause
  on a first install; the JWT is the usual cause for the licence).
- **`bnk-license is stuck: Device registration in progress`** (proxy mode) —
  `bnk up` gives up after the licence state has not changed for five minutes and
  prints the recovery. The CWC obtained its certificate but never sent the
  registration: the proxy's log shows a `POST /license-proxy/v1/certificates`
  and no `POST /license-proxy/v1/entitlements/telemetry`, and the CWC logs
  `ResponseCM20GetBackLater` every five seconds. It is a BNK defect, not a
  configuration error, and intermittent (seen once in six proxy installs). The
  reliable recovery is a fresh install: set `lifecycle: down`, sync, set it
  back to `up`, sync.
- **`registry CA … unreachable from node`** — the registry-CA DaemonSet could
  not reach the mirror from every node: a Transit Gateway or security-group
  problem, not a BNK one.
- **A 403 from GCP naming a project** — the FAR pull key in COS is the wrong
  one for the manifest version (GA key vs EA key).

Fix the cause and **Sync** again: the apply is idempotent and continues from
the Terraform state on the PVC.

## "bnk down completed" but the Application went Degraded

roksbnkctl's `bnk status --json` reports `deployed: true` whenever the phase's
state file exists — including right after a destroy, when it holds zero
resources. The hooks cross-check the Terraform state's resource count before
writing `deployed`; if you see this symptom, the chart in use predates that
check — update it.

## Argo CD says OutOfSync right after a successful sync

Expected once: the hooks patched `bnk-status`, and Argo CD compares it with
the rendered placeholder. The Application's `ignoreDifferences` on that
ConfigMap's `/data` (plus `RespectIgnoreDifferences=true`) hides it. If you
created the Application by hand, make sure both are present.

## The PVC stays Pending and the sync never starts

The storage class binds WaitForFirstConsumer and the claim is in a wave of its
own. The chart puts the claim in wave −4 with `bnk-init`; check nothing
overrode `argocd.argoproj.io/sync-wave` on it.

## Deleting the Application hangs

The PreDelete hook is running `bnk down` — give it the time a destroy needs
(the `down` timeout).

If the Application was **never synced** (created, then deleted without a
sync), the hook cannot even start: its ServiceAccount and ConfigMaps do not
exist, the Job never gets a pod, and Argo CD waits for it. Nothing is
installed in that case, so remove the finalizer and let the deletion complete:

```bash
kubectl -n argocd patch application bnk-<ws> --type json -p '[{"op":"remove","path":"/metadata/finalizers"}]'
```

(`argocd app delete --cascade=false` before the fact achieves the same.) If it fails, the Application stays with a deletion
timestamp; look at `bnk-predelete`'s pod logs while they exist, fix the cause
(usually a stuck finalizer on an F5 CR) and delete again. As a last resort
remove the finalizer from the Application — the resources will be orphaned,
and `bnk down` must be run another way.

## Where roksbnkctl's own troubleshooting starts

Everything above is Argo CD plumbing. The installer's behaviour — guards,
Terraform modules, the F5 components — is documented in the roksbnkctl book's
troubleshooting chapter, and every hook log is exactly the output that book
describes.
