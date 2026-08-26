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
| `line` | derived | BNK line, major.minor of `config.bnk.manifest_version`. Set explicitly only to override. `2.3` enables the cwc-guard container (`cwcGuard.enabled: auto`). |

## Runner

| Value | Default | Meaning |
|---|---|---|
| `runner.image` / `runner.tag` | `ghcr.io/jgruberf5/roksbnkctl-tools-runner` / `v1.54.0` | The roksbnkctl runner image. Mirror it for air-gapped hubs. |
| `runner.imagePullPolicy` | `IfNotPresent` | |
| `runner.imagePullSecrets` | `[]` | For a private mirror. |
| `runner.env` | `{}` | Extra plain variables on every hook container (rarely needed). |
| `runner.extraEnvFrom` | `[]` | Extra `envFrom` sources, e.g. `[{secretRef: {name: flp-handoff}}]`. |
| `runner.resources` | 250m/512Mi – 2 CPU/2Gi | Terraform + Helm need the headroom. |
| `runner.fsGroup` | `0` | The runner is uid 1000 / gid 0. |
| `runner.runAsUser` | unset | Leave unset on OpenShift (the SCC assigns a uid); set `1000` on k3s/kind. |
| `runner.nodeSelector` / `runner.tolerations` | `{}` / `[]` | |

The runner keeps the workspace at `/work/.roksbnkctl/<workspace>` on the PVC,
including the admin kubeconfig it fetches.

## Cluster

| Value | Default | Meaning |
|---|---|---|
| `config.cluster.create` | — | `false`: `bnk-cluster` runs `cluster register <config.cluster.name>`. `true` (hub): it runs `cluster up --auto` and builds the cluster `config.cluster` describes. |
| `config.cluster.name` | — | The existing cluster to register, or the name of the cluster to build. |
| `cluster.registryCosName` | `""` | Only when the registry COS instance is not named `<prefix>-registry-cos` (roksbnkctl's convention, which `cluster register` tries first). |
| `teardown.cluster` | `false` | With `config.cluster.create: true`: the PreDelete hook also runs `tgw disconnect` and `cluster down`. |
| `flp.deploy` | `false` | Deploy the F5 License Proxy described by `config.bnk.flp` from this workspace: the `bnk-flp` hook runs `flp up --auto` before `bnk up` ([Appendix B](appendix-b-private-registry-flp.md)). |
| `teardown.flp` | `true` | With `flp.deploy: true`: `flp down` after `bnk down` on delete / `lifecycle: down`. |

## Registry mirror

| Value | Default | Meaning |
|---|---|---|
| `registry.mode` | derived | `adopt` when `config.registry` names a mirror (`bnk-registry` runs `registry adopt`), else `none` (pull from FAR). Set `replicate` when the pod can reach FAR and should populate the mirror itself. |
| `registry.target` | `generic` | `icr` or `generic` (only when `mode` ≠ `none`). |

The mirror itself — host, repository prefix, username, CA — is described in
`config.registry` (roksbnkctl's schema); the password lives in `bnk-secrets`.

## Upgrades

| Value | Default | Meaning |
|---|---|---|
| `upgrade.strategy` | `down-then-up` | BNK 2.3/2.4 have no in-place upgrade. On a manifest-version change against an applied workspace: `down-then-up` runs `bnk down` then `bnk up` in the `bnk-up` hook; `refuse` fails the preflight gate and asks for an explicit `lifecycle: down` sync first. Never an in-place apply. |

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
| `secrets.name` | `bnk-secrets` | Keys roksbnkctl reads: `IBMCLOUD_API_KEY` (required); `ROKSBNKCTL_GENERIC_PASSWORD` (mirror), `ROKSBNKCTL_BIGIP_PASSWORD`, `ROKSBNKCTL_GTM_PASSWORD`, `ROKSBNKCTL_COS_HMAC_ACCESS_KEY` / `_SECRET_KEY` (remote state) as needed. |
| `secrets.externalSecret.*` | | `storeRef`, `refreshInterval`, `data[]` (`key` + `remoteRef`). |
| `flpHandoff.writeSecret` / `secretName` | `false` / `flp-handoff` | Let the runner create/patch the F5 License Proxy hand-off Secret. |

## Workspace (`config`)

`config` is roksbnkctl's `config.yaml`, verbatim (`roksbnkctl init example`
prints the schema; the roksbnkctl book's *Workspace config* chapter documents
every key). The chart:

- merges `sizing.profile` into `cluster.workers_per_zone`,
  `cluster.worker_flavor`, `bnk.tmm_replicas`, `bnk.cneinstance_size`;
- refuses `bnk.cneinstance_size` other than `Tiny` on the 2.4 line (unless
  `sizing.allowNonTinyDeploymentSize`), and refuses any `api_key_b64` /
  `*password_b64` key — secrets belong in `bnk-secrets`;
- renders it into the `bnk-config` ConfigMap (`workspaceConfig.configMapName`,
  wave −10), mounts it at `workspaceConfig.mountPath` (`/config`), and seeds
  the workspace from it in the `bnk-init` hook, with the Secret applied on top;
- reads `cluster.create`, `cluster.name`, `bnk.manifest_version` and
  `registry.target` from it — at render time for the hook selection, the
  derived `line`, `registry.mode` and the labels; in the hooks (from the
  mounted file) for `cluster register`, the version-change check and the
  preflight gate. Nothing from `config` is copied anywhere else.

The blocks a workspace typically sets:

| Block | Keys | |
|---|---|---|
| `ibmcloud` | `region`, `resource_group` | required |
| `prefix` | | required — the name prefix for everything roksbnkctl creates |
| `tf_source` | `type: embedded` | required |
| `cluster` | `create`, `name`, `openshift_version`, `network_mode`, `vpc_cidr` | register an existing cluster or describe a new one |
| `resources.transit_gateway` | `create: false, existing: <name-or-id>` | adopt a shared gateway |
| `bnk` | `manifest_version`, `far_repo_url`, `far_auth_file`, `subscription_jwt_file`, `license_mode`, `flp`, `network.zones` | the BNK version and supply chain; `tmm_replicas` / `cneinstance_size` come from the sizing profile |
| `cos` | `instance`, `bucket`, `region` | where the FAR key and JWT live |
| `registry` | `target`, `generic_host`, `generic_repo_prefix`, `generic_username`, `generic_ca` | a Harbor/Artifactory mirror (with `registry.mode` in the overlay) |
| `state` | `backend: s3`, `s3.{endpoint,bucket,region,key_prefix}` | COS remote-state backend |
| `gateway` | | the optional gateway phase |

## Status, hooks, timeouts

| Value | Default | Meaning |
|---|---|---|
| `status.configMapName` | `bnk-status` | The status ConfigMap the Lua health check reads. |
| `hooks.deletePolicy` | `BeforeHookCreation` | Keep the last run's Jobs (including failed ones) until the next sync. |
| `preDelete.enabled` | `true` | Render the PreDelete hook (Argo CD ≥ 3.3). |
| `timeouts.init` / `cluster` / `flp` / `registry` / `preflight` / `apply` / `status` / `down` | 600 / 7200 / 3600 / 7200 / 900 / 7200 / 300 / 5400 | `activeDeadlineSeconds` per hook Job. |
