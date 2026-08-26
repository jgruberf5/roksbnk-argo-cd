# kind verification — scenario 5: version change = bnk down then bnk up (commit e6c4bed)

Installed at 2.4.0-0.0.1 (scenario 5a). Stub `bnk up` fails loudly if a different version is applied over an installed one — i.e. if the chart ever attempted an in-place upgrade.

== 5a. re-sync at 2.4.0-0.0.1 (fixed chart; no version change → no-op)
Failed|Synced|Degraded
outcome=failed deployed=true sync failed (hooks: bnk-preflight) — preflight: BNK line change 2.4 -> down-then-up is refused on an applied workspace (bnk down first); logs: kubectl -n bnk-kindstub logs -l roksbnkctl.io/workspace=kindstub --tail=200
== 5b. bump ROKSBNKCTL_MANIFEST_VERSION → 2.4.1-0.0.1, sync (expect bnk down, then bnk up)
Failed|OutOfSync|Degraded
outcome=failed deployed=true sync failed (hooks: bnk-preflight) — preflight: BNK line change 2.4 -> down-then-up is refused on an applied workspace (bnk down first); logs: kubectl -n bnk-kindstub logs -l roksbnkctl.io/workspace=kindstub --tail=200

## job/bnk-preflight
    [status] failed deployed=true — preflight: BNK line change 2.4 -> down-then-up is refused on an applied workspace (bnk down first)
    preflight: BNK line change 2.4 -> down-then-up is refused on an applied workspace (bnk down first)

## job/bnk-up
    [status] running deployed=unknown — bnk up in progress
    [stub roksbnkctl] guards ok · terraform plan: 47 to add
    [stub roksbnkctl] terraform apply (cert-manager → flo → cneinstance → license) (20s)
    [stub roksbnkctl] bnk up: License bnk-license Active · CNEInstance Available · done
    [status] succeeded deployed=true — bnk up completed

== 5c. upgrade.strategy=refuse + bump → 2.4.2-0.0.1, sync (expect preflight refusal, no new bnk-up)
