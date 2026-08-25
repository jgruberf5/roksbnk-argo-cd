# kind verification — scenario 1: bnk up (commit a4a923a)

HOOK       WAVE   JOB             STARTED                SUCCEEDED   FAILED
SyncFail   0      bnk-syncfail    2026-08-25T18:28:28Z   <none>      <none>
Sync       -4     bnk-init        2026-08-25T18:50:21Z   1           <none>
Sync       -3     bnk-cluster     2026-08-25T18:50:28Z   1           <none>
Sync       -1     bnk-preflight   2026-08-25T18:50:31Z   1           <none>
Sync       0      bnk-up          2026-08-25T18:50:35Z   1           <none>
PostSync   0      bnk-status      2026-08-25T18:50:58Z   1           <none>

## job/bnk-init
    [stub roksbnkctl] init: workspace kindstub written to /work/.roksbnkctl/kindstub/config.yaml (8 overrides)
    roksbnkctl stub (simulates v1.54.0); terraform stub; helm stub
    [stub roksbnkctl] doctor: terraform ok · helm ok · kubectl ok · api key ok · workspace /work/.roksbnkctl/kindstub ok

## job/bnk-cluster
    [stub roksbnkctl] cluster register: attached kind-existing-roks → /work/.roksbnkctl/kindstub/cluster-outputs.json
    [stub roksbnkctl] kubeconfig --download: wrote /work/.roksbnkctl/kindstub/.kube/config

## job/bnk-preflight
    preflight: ok (deployed=unknown)

## job/bnk-up
    [status] running deployed=unknown — bnk up in progress
    [stub roksbnkctl] guards ok · terraform plan: 47 to add
    [stub roksbnkctl] terraform apply (cert-manager → flo → cneinstance → license) (20s)
    [stub roksbnkctl] bnk up: License bnk-license Active · CNEInstance Available · done
    [status] succeeded deployed=true — bnk up completed

## job/bnk-status
    [status] succeeded deployed=true — post-sync bnk status captured
    bnk phase: deployed=true (workspace kindstub, line 2.4)

