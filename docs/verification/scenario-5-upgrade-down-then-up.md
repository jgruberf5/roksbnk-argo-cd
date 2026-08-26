# kind verification — scenario 5: version change = bnk down then bnk up (commit 15ff1f1)

== 5a. fresh install at 2.4.0-0.0.1
Succeeded|Synced|Healthy
outcome=succeeded deployed=true post-sync bnk status captured
== 5b. bump ROKSBNKCTL_MANIFEST_VERSION → 2.4.1-0.0.1, sync (expect bnk down, then bnk up)
Failed|OutOfSync|Degraded
outcome=failed deployed=true sync failed (hooks: bnk-preflight) — preflight: upgrade.strategy must be down-then-up or refuse; logs: kubectl -n bnk-kindstub logs -l roksbnkctl.io/workspace=kindstub --tail=200

## job/bnk-preflight
    preflight: upgrade.strategy must be down-then-up or refuse
    [status] failed deployed=true — preflight: upgrade.strategy must be down-then-up or refuse

## job/bnk-up
    [status] running deployed=unknown — bnk up in progress
    [stub roksbnkctl] guards ok · terraform plan: 47 to add
    [stub roksbnkctl] terraform apply (cert-manager → flo → cneinstance → license) (20s)
    [stub roksbnkctl] bnk up: License bnk-license Active · CNEInstance Available · done
    [status] succeeded deployed=true — bnk up completed

== 5c. upgrade.strategy=refuse + bump → 2.4.2-0.0.1, sync (expect preflight refusal, no bnk-up)
Failed|OutOfSync|Degraded
outcome=failed deployed=true sync failed (hooks: bnk-preflight) — preflight: upgrade.strategy must be down-then-up or refuse; logs: kubectl -n bnk-kindstub logs -l roksbnkctl.io/workspace=kindstub --tail=200

## job/bnk-preflight (refuse)
    [status] failed deployed=true — preflight: upgrade.strategy must be down-then-up or refuse
    preflight: upgrade.strategy must be down-then-up or refuse

## bnk-up job start time (must be from 5b, not re-created): 2026-08-26T11:01:09Z
