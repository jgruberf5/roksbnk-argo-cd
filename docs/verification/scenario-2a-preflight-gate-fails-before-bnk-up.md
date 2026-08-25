# kind verification — scenario 2a: preflight gate fails before bnk up (commit 0eaf076)

sync: Synced  health: Healthy  op: Succeeded — successfully synced (no more tasks)
bnk-status: lifecycle=down outcome=succeeded deployed=false hook=bnk-status
  post-sync bnk status captured

HOOK       WAVE   JOB             STARTED                SUCCEEDED   FAILED
Sync       0      bnk-up          2026-08-25T18:50:35Z   1           <none>
Sync       -3     bnk-cluster     2026-08-25T18:51:46Z   1           <none>
Sync       -2     bnk-registry    2026-08-25T18:51:49Z   1           <none>
Sync       -1     bnk-preflight   2026-08-25T18:51:56Z   <none>      1
SyncFail   0      bnk-syncfail    2026-08-25T18:53:00Z   1           <none>
Sync       -4     bnk-init        2026-08-25T18:53:58Z   1           <none>
Sync       0      bnk-down        2026-08-25T18:54:04Z   1           <none>
PostSync   0      bnk-status      2026-08-25T18:54:08Z   1           <none>

## job/bnk-registry
    [stub roksbnkctl] registry adopt (1s)
    [stub roksbnkctl] registry adopt: wrote /work/.roksbnkctl/kindstub/registry-mirror.json (missing_count=3)

## job/bnk-preflight
    [status] failed deployed=true — preflight: registry mirror incomplete: 3 artifacts missing (registry verify)
    preflight: registry mirror incomplete: 3 artifacts missing (registry verify)

## job/bnk-syncfail
    [status] failed deployed=unknown — sync failed: bnk down completed

