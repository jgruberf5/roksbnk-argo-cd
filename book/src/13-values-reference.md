# Chart values

`charts/bnk-workspace/values.yaml` documents every value; this is the reference
for the ones a workspace overlay sets. Overlays live in
`apps/overlays/<workspace>/values.yaml` and override these defaults.

## Identity and lifecycle

| Value | Default | Meaning |
|---|---|---|
| `workspace` | `bnk` | roksbnkctl workspace name (`-w`). Also the `roksbnkctl.io/workspace` label on everything the chart renders. |
| `namespace` | `bnk-ci` | Namespace the hook Jobs and the PVC live in — the Application's destination namespace. |
| `createNamespace` | `false` | Render a `Namespace`; otherwise rely on the Application's `CreateNamespace=true`. |
| `lifecycle` | `up` | `up` → the Sync hook runs `bnk up --auto`. `down` → it runs `bnk down --auto` (tear BNK down while keeping the Application; the only teardown path before Argo CD 3.3). |
| `topology` | `in-target` | `in-target` (Argo CD on the ROKS cluster) or `hub` (Argo CD on a management cluster). Informational today — the hooks behave the same; `cluster.create: true` only makes sense on a hub. |
| `line` | `"2.4"` | BNK line. `"2.3"` enables the cwc-guard container (`cwcGuard.enabled: auto`). |

## Runner

| Value | Default | Meaning |
|---|---|---|
| `runner.image` / `runner.tag` | `ghcr.io/jgruberf5/roksbnkctl-tools-runner` / `v1.54.0` | The roksbnkctl runner image. Mirror it for air-gapped hubs. |
| `runner.imagePullPolicy` | `IfNotPresent` | |
| `runner.imagePullSecrets` | `[]` | For a private mirror. |
| `runner.env` | `{}` | Extra plain environment on every hook container. |
| `runner.extraEnvFrom` | `[]` | Extra `envFrom` sources, e.g. `[{secretRef: {name: flp-handoff}}]`. |
| `runner.resources` | 250m/512Mi – 2 CPU/2Gi | Terraform + Helm need the headroom. |
| `runner.fsGroup` | `0` | The runner is uid 1000 / gid 0. |
| `runner.runAsUser` | unset | Leave unset on OpenShift (the SCC assigns a uid); set `1000` on k3s/kind. |
| `runner.nodeSelector` / `runner.tolerations` | `{}` / `[]` | |

The runner always gets `ROKSBNKCTL_HOME=/work/.roksbnkctl`, `HOME=/home/runner`,
`KUBECONFIG=/work/.roksbnkctl/.kube/config` and `WS=<workspace>`.

## Cluster

| Value | Default | Meaning |
|---|---|---|
| `cluster.create` | `false` | `false`: `bnk-cluster` runs `cluster register <cluster.name>`. `true` (hub): it runs `cluster up --auto` and builds the cluster described by the `ROKSBNKCTL_*` keys. |
| `cluster.name` | `""` | → `ROKSBNKCTL_CLUSTER_NAME`. Required when `create: false`. |
| `cluster.registryCosName` | `""` | → `REGISTRY_COS_NAME`, passed as `cluster register --registry-cos-name`. |
| `teardown.cluster` | `false` | With `cluster.create: true`: the PreDelete hook also runs `tgw disconnect` and `cluster down`. |

## Registry mirror

| Value | Default | Meaning |
|---|---|---|
| `registry.mode` | `none` | `none`: pull from FAR. `adopt`: a mirror populated elsewhere — `bnk-registry` runs `registry adopt`. `replicate`: the pod can reach FAR — it runs `registry target/bom/replicate/verify`. |
| `registry.target` | `generic` | `icr` or `generic` → `ROKSBNKCTL_REGISTRY_TARGET` (only when `mode` ≠ `none`). |

The mirror host, prefix, username and CA go in `env` (`ROKSBNKCTL_GENERIC_*`);
the password in `bnk-secrets` (`ROKSBNKCTL_GENERIC_PASSWORD`).

## Gates

| Value | Default | Meaning |
|---|---|---|
| `preflight.doctor` | `true` | Run `roksbnkctl doctor` in the `bnk-init` hook (IAM auth, quota, tools). |
| `preflight.command` | `""` | Replace the shell replica of the file guards with a roksbnkctl verb once `bnk preflight` exists. |
| `cwcGuard.enabled` | `auto` | `auto` = on for line 2.3 only. The f5-spk-cwc Multi-Attach workaround, as a second container in the `bnk-up` Job. |
| `cwcGuard.script` | (embedded) | The guard's loop; exits when `/signal/done` appears. |

## Storage, identity, secrets

| Value | Default | Meaning |
|---|---|---|
| `storage.claimName` | `bnk-work` | The workspace PVC. `Prune=false`, `Delete=false`, wave −4. |
| `storage.size` / `storage.accessMode` | `8Gi` / `ReadWriteOnce` | |
| `storage.storageClassName` | `""` | `ibmc-vpc-block-10iops-tier` on ROKS; `local-path` on k3s. |
| `serviceAccount.name` | `bnk-runner` | Namespaced Role: ConfigMaps (status), Jobs get/list (SyncFail names the failed hooks), optionally the FLP hand-off Secret. |
| `secrets.mode` | `existing` | `existing`, `externalSecret` (renders an ESO `ExternalSecret`), `inline` (dev only), `none`. |
| `secrets.name` | `bnk-secrets` | Keys: `IBMCLOUD_API_KEY`, and as needed `ROKSBNKCTL_GENERIC_PASSWORD`, `ROKSBNKCTL_BIGIP_PASSWORD`, `ROKSBNKCTL_GTM_PASSWORD`. |
| `secrets.externalSecret.*` | | `storeRef`, `refreshInterval`, `data[]` (`key` + `remoteRef`). |
| `flpHandoff.writeSecret` / `secretName` | `false` / `flp-handoff` | Let the runner create/patch the F5 License Proxy hand-off Secret. |

## Environment (`env`)

Every key under `env` becomes an entry in the `bnk-env` ConfigMap and is read by
`roksbnkctl init --non-interactive --override-from-env`. The chart merges four
derived keys underneath (`ROKSBNKCTL_CLUSTER_CREATE`, `ROKSBNKCTL_CLUSTER_NAME`,
`ROKSBNKCTL_REGISTRY_TARGET`, `REGISTRY_COS_NAME`); anything you set wins.
Empty values are skipped by roksbnkctl, which is how a connected overlay can
"blank" a mirror setting inherited from elsewhere.

The keys used in this book:

| Key | Example | |
|---|---|---|
| `ROKSBNKCTL_REGION` / `_RESOURCE_GROUP` / `_PREFIX` | `us-east` / `default` / `sm-cli` | required by `init` |
| `ROKSBNKCTL_OPENSHIFT_VERSION` | `"4.21"` | |
| `ROKSBNKCTL_CLUSTER_NETWORK_MODE` | `single-nic` | must match the registered cluster |
| `ROKSBNKCTL_TRANSIT_GATEWAY_NAME` | `sm-cli-tgw` | existing gateway, by name or id |
| `ROKSBNKCTL_WORKERS_PER_ZONE` / `_WORKER_FLAVOR` | `"2"` / `bx2.8x32` | cluster size (see [Sizing](09-sizing.md)) |
| `ROKSBNKCTL_CLUSTER_VPC_CIDR` | `10.252.0.0/16` | new clusters on a shared gateway |
| `ROKSBNKCTL_MANIFEST_VERSION` | `2.4.0-EA` | selects the 2.4 line |
| `ROKSBNKCTL_FAR_AUTH_FILE` / `_SUBSCRIPTION_JWT_FILE` | `non-ga-prod-pull-key.tgz` / `subscription.jwt` | objects in the COS bucket |
| `ROKSBNKCTL_COS_INSTANCE` / `_COS_BUCKET` / `_COS_REGION` | | the supply-chain bucket |
| `ROKSBNKCTL_CNEINSTANCE_SIZE` | `Tiny` | always `Tiny` on ROKS |
| `ROKSBNKCTL_TMM_REPLICAS` | `"3"` | |
| `ROKSBNKCTL_LICENSE_MODE` | `subscription` / `f5licenseproxy` | FLP needs the hand-off (`ROKSBNKCTL_FLP_EXTERNAL_URL`, `ROKSBNKCTL_FLP_ROOT_CA_B64`) |

The full list is in the roksbnkctl book, chapter *Unattended setup*.

## Status, hooks, timeouts

| Value | Default | Meaning |
|---|---|---|
| `status.configMapName` | `bnk-status` | The status ConfigMap the Lua health check reads. |
| `hooks.deletePolicy` | `BeforeHookCreation` | Keep the last run's Jobs (including failed ones) until the next sync. |
| `preDelete.enabled` | `true` | Render the PreDelete hook (Argo CD ≥ 3.3). |
| `timeouts.init` / `cluster` / `registry` / `preflight` / `apply` / `status` / `down` | 600 / 7200 / 7200 / 900 / 7200 / 300 / 5400 | `activeDeadlineSeconds` per hook Job. |
