# kind verification — scenario 2b: apply failure inside bnk up (commit 0b7cf3a)

sync: Synced  health: Degraded  op: Failed — one or more synchronization tasks completed unsuccessfully
bnk-status: lifecycle=up outcome=failed deployed=false hook=bnk-syncfail
  sync failed — bnk up exited with status 1 — see job/bnk-up logs; logs: kubectl -n bnk-kindstub logs -l roksbnkctl.io/workspace=kindstub --tail=200

HOOK       WAVE   JOB             STARTED                SUCCEEDED   FAILED
Sync       0      bnk-down        2026-08-25T18:54:04Z   1           <none>
PostSync   0      bnk-status      2026-08-25T18:54:08Z   1           <none>
Sync       -4     bnk-init        2026-08-25T18:54:53Z   1           <none>
Sync       -3     bnk-cluster     2026-08-25T18:54:58Z   1           <none>
Sync       -2     bnk-registry    2026-08-25T18:55:04Z   1           <none>
Sync       -1     bnk-preflight   2026-08-25T18:55:10Z   1           <none>
Sync       0      bnk-up          2026-08-25T18:55:15Z   <none>      1
SyncFail   0      bnk-syncfail    2026-08-25T18:55:39Z   1           <none>

## job/bnk-up
    [status] running deployed=unknown — bnk up in progress
    [stub roksbnkctl] guards ok · terraform plan: 47 to add
    [stub roksbnkctl] terraform apply (cert-manager → flo → cneinstance → license) (20s)
    error: terraform apply failed after 5 attempts: helm_release.flo: timed out waiting for f5-lifecycle-operator rollout
    [status] failed deployed=false — bnk up exited with status 1 — see job/bnk-up logs

## job/bnk-syncfail
    [status] failed deployed=false — sync failed — bnk up exited with status 1 — see job/bnk-up logs; logs: kubectl -n bnk-kindstub logs -l roksbnkctl.io/workspace=kindstub --tail=200

