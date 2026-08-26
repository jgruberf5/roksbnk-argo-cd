# kind verification — scenario 6: workspace from config.yaml (commit 75aa213)

Overlay switched from env: to config: (version 2.4.0-0.0.1, Small profile); the workspace had 2.4.1 installed from scenario 5, so this sync is also a down-then-up. Expect: bnk-config ConfigMap synced, init seeds from /config/config.yaml, preflight announces the version change, bnk-up runs bnk down then bnk up, Healthy.

Succeeded|Synced|Healthy
outcome=succeeded deployed=true post-sync bnk status captured

## configmap/bnk-config
    # rendered by the bnk-workspace chart — edit apps/overlays/<workspace>/values.yaml (config:)
    bnk:
      cneinstance_size: Tiny
      license_mode: subscription
      manifest_version: 2.4.0-0.0.1
      tmm_replicas: 3
    cluster:
      create: false
      name: kind-existing-roks
      worker_flavor: bx2.8x32
      workers_per_zone: 2
    ibmcloud:
      region: us-south
      resource_group: default
    prefix: kindstub
    tf_source:
      type: embedded

## job/bnk-init
    [stub roksbnkctl] init: seeded workspace kindstub from /config/config.yaml (17 lines), env overrides applied
    roksbnkctl stub (simulates v1.54.0); terraform stub; helm stub
    [stub roksbnkctl] doctor: terraform ok · helm ok · kubectl ok · api key ok · workspace /work/.roksbnkctl/kindstub ok

## job/bnk-preflight
    preflight: BNK version change 2.4.1-0.0.1 -> 2.4.0-0.0.1 — no in-place upgrade exists; bnk-up will run bnk down, then bnk up (upgrade.strategy=down-then-up)
    preflight: ok (deployed=true)

## job/bnk-up
    [status] running deployed=unknown — bnk up in progress
    [status] running deployed=true — upgrading BNK 2.4.1-0.0.1 -> 2.4.0-0.0.1: bnk down (no in-place upgrade), then bnk up
    == BNK version change 2.4.1-0.0.1 -> 2.4.0-0.0.1: running bnk down first (BNK does not support in-place upgrades)
    [stub roksbnkctl] terraform destroy (license → cneinstance → flo → cert-manager) (8s)
    [stub roksbnkctl] bnk down: done (applied-tfvars snapshot kept, as the real CLI does)
    == bnk down complete; installing 2.4.0-0.0.1
    [stub roksbnkctl] guards ok · terraform plan: 47 to add
    [stub roksbnkctl] terraform apply (cert-manager → flo → cneinstance → license) (20s)
    [stub roksbnkctl] bnk up: License bnk-license Active · CNEInstance Available · done
    [status] succeeded deployed=true — bnk up completed
