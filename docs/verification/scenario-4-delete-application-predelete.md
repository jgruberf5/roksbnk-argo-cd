# kind verification — scenario 4: redeploy, then delete the Application (commit 1d513bd)

Argo CD v3.5.1 (`--core`), kind v0.32, stub runner `roksbnkctl-stub:dev`.

## 4a · redeploy after the failed apply (STUB_FAIL_APPLY removed)

```
sync: Synced  health: Healthy  op: Succeeded — successfully synced (no more tasks)
bnk-status: lifecycle=up outcome=succeeded deployed=true hook=bnk-status
```

## 4b · `kubectl -n argocd delete application bnk-kindstub`

Application carries `resources-finalizer.argocd.argoproj.io`; the chart renders
`bnk-predelete` with `argocd.argoproj.io/hook: PreDelete`.

```
t+3s  predelete=/ app=2026-08-25T18:57:25Z      # Job exists, running
t+6s  predelete=/ app=2026-08-25T18:57:25Z
t+9s  predelete=/ app=2026-08-25T18:57:25Z
t+12s predelete=none app=GONE                    # hook finished, Application and resources removed
```

Namespace events:

```
Normal  SuccessfulCreate  job/bnk-predelete        Created pod: bnk-predelete-84nzf
Normal  Scheduled         pod/bnk-predelete-84nzf  Successfully assigned bnk-kindstub/bnk-predelete-84nzf to bnk-argocd-control-plane
Normal  Started           pod/bnk-predelete-84nzf  Container started
Normal  Completed         job/bnk-predelete        Job completed
```

Left in the namespace afterwards: only the PVC (`Prune=false,Delete=false`):

```
persistentvolumeclaim/bnk-work   Bound   pvc-00a1376d-…   1Gi   RWO   standard
```

Workspace state on the retained PVC (debug pod mounting `bnk-work`):

```
/work/.roksbnkctl/kindstub
  .kube/  cluster-outputs.json  config.yaml  registry-mirror.json  state/  state-cluster/
  state/terraform.applied.tfvars            # kept, as the real CLI does
tfstate-present: no                          # bnk down ran
applied-snapshot-present: yes
{"phase":"bnk","deployed":false}
```

Note: Argo CD removes the PreDelete hook Job together with the Application, so its
logs are not retained — the evidence is the events and the workspace state. On a
real cluster `bnk down`'s own output is best captured by the runner (`journal`)
or by shipping Job logs to the cluster's log stack.
