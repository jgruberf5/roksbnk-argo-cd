# kind verification — scenario 5: version change = bnk down then bnk up (commit 9c2e929)

Installed at 2.4.0-0.0.1 (scenario 5a). The stub `bnk up` fails loudly if a different version is applied over an installed one — i.e. if the chart ever attempted an in-place upgrade.

== 5a. re-sync at 2.4.0-0.0.1 (no version change → no-op)
Succeeded|Synced|Healthy
outcome=succeeded deployed=true post-sync bnk status captured
== 5b. bump ROKSBNKCTL_MANIFEST_VERSION → 2.4.1-0.0.1, sync (expect bnk down, then bnk up)
Succeeded|Synced|Healthy
outcome=succeeded deployed=true post-sync bnk status captured

## job/bnk-preflight
    preflight: BNK version change 2.4.0-0.0.1 -> 2.4.1-0.0.1 — no in-place upgrade exists; bnk-up will run bnk down, then bnk up (upgrade.strategy=down-then-up)
    preflight: ok (deployed=true)

## job/bnk-up
    [status] running deployed=unknown — bnk up in progress
    [status] running deployed=true — upgrading BNK 2.4.0-0.0.1 -> 2.4.1-0.0.1: bnk down (no in-place upgrade), then bnk up
    == BNK version change 2.4.0-0.0.1 -> 2.4.1-0.0.1: running bnk down first (BNK does not support in-place upgrades)
    [stub roksbnkctl] terraform destroy (license → cneinstance → flo → cert-manager) (8s)
    [stub roksbnkctl] bnk down: done (applied-tfvars snapshot kept, as the real CLI does)
    == bnk down complete; installing 2.4.1-0.0.1
    [stub roksbnkctl] guards ok · terraform plan: 47 to add
    [stub roksbnkctl] terraform apply (cert-manager → flo → cneinstance → license) (20s)
    [stub roksbnkctl] bnk up: License bnk-license Active · CNEInstance Available · done
    [status] succeeded deployed=true — bnk up completed

== 5c. upgrade.strategy=refuse + bump → 2.4.2-0.0.1, sync (expect preflight refusal, no new bnk-up)
