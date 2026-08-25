# kind verification — scenario 4a: redeploy after failure (commit 1d513bd)

sync: Synced  health: Healthy  op: Succeeded — successfully synced (no more tasks)
bnk-status: lifecycle=up outcome=succeeded deployed=true hook=bnk-status
  post-sync bnk status captured

HOOK       WAVE   JOB             STARTED                SUCCEEDED   FAILED
Sync       0      bnk-down        2026-08-25T18:54:04Z   1           <none>
SyncFail   0      bnk-syncfail    2026-08-25T18:55:39Z   1           <none>
Sync       -4     bnk-init        2026-08-25T18:56:34Z   1           <none>
Sync       -3     bnk-cluster     2026-08-25T18:56:39Z   1           <none>
Sync       -2     bnk-registry    2026-08-25T18:56:44Z   1           <none>
Sync       -1     bnk-preflight   2026-08-25T18:56:50Z   1           <none>
Sync       0      bnk-up          2026-08-25T18:56:55Z   1           <none>
PostSync   0      bnk-status      2026-08-25T18:57:19Z   1           <none>

## job/bnk-up
    [status] running deployed=unknown — bnk up in progress
    [stub roksbnkctl] guards ok · terraform plan: 47 to add
    [stub roksbnkctl] terraform apply (cert-manager → flo → cneinstance → license) (20s)
    [stub roksbnkctl] bnk up: License bnk-license Active · CNEInstance Available · done
    [status] succeeded deployed=true — bnk up completed

## job/bnk-status
    [status] succeeded deployed=true — post-sync bnk status captured
    bnk phase: deployed=true (workspace kindstub, line 2.4)

