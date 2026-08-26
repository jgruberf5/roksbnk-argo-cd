# Small, Medium and Large clusters

F5's *BIG-IP Next for Kubernetes on ROKS — Single-NIC Sizing Guide* describes
three **cluster** sizes. roksbnkctl's book reproduces the figures and records a
verified reference deployment for each one (its Appendix C); this chapter shows
how each size is expressed as an Argo CD workspace overlay.

## The one thing to get right

The names Small, Medium and Large are **cluster** sizes — node flavour, node
count and TMM pod count. They are **not** the BNK `deploymentSize`. On ROKS the
`CNEInstance` `deploymentSize` stays **`Tiny`** for every cluster size: anything
larger requests hugepages, which a ROKS worker cannot provide (there are no
MachineConfigPools to enable them), and the failure is silent. Capacity comes
from `tmmReplicas` and from bigger nodes, never from a bigger BNK profile — the
Large cluster reaches ~31 Gbit/s by running nine TMM pods on nine large nodes.

| | Small | Medium | Large |
|---|---|---|---|
| Worker nodes | 6 (2 per AZ) | 6 (2 per AZ) | 9 (3 per AZ) |
| Flavour | `bx2.8x32` | `cx2.16x32` | `cx2.48x96` |
| `deploymentSize` | `Tiny` | `Tiny` | `Tiny` |
| `tmmReplicas` | 3 | 3 | 9 |
| L4 ingress, cluster (F5 figure) | ~7.8 Gbit/s | ~10.4 Gbit/s | ~31 Gbit/s |
| Verified by roksbnkctl on ROKS | yes | yes | yes |

F5's guide recommends `bx2.8x32` for Small over the reference-tested
`cx3d.8x20` — the balanced flavour leaves roughly four times the memory for
applications. It also reports `cx2.8x16` as leaving 0.1 % memory free; the tool
will build it, but it will not hold the platform.

The cluster this book installs onto — `sm-cli`, six `bx2.8x32` workers, two per
zone, `tmmReplicas: 3` — **is the Small cluster**.

## One line chooses the size

The overlay names the size; the chart writes the node count, the flavour and
the TMM pod count into the workspace's `config.yaml` (`cluster.workers_per_zone`,
`cluster.worker_flavor`, `bnk.tmm_replicas`) and pins `bnk.cneinstance_size:
Tiny`. Everything else — region, supply chain, manifest version — is common.
The repository ships one overlay per size under `apps/overlays/`:

```yaml
# apps/overlays/bnk-small/values.yaml (excerpt)
sizing:
  profile: small            # → workers_per_zone: 2, worker_flavor: bx2.8x32, tmm_replicas: 3, cneinstance_size: Tiny
```

```yaml
# apps/overlays/bnk-medium/values.yaml (excerpt)
sizing:
  profile: medium           # → workers_per_zone: 2, worker_flavor: cx2.16x32, tmm_replicas: 3, cneinstance_size: Tiny
```

```yaml
# apps/overlays/bnk-large/values.yaml (excerpt)
sizing:
  profile: large            # → workers_per_zone: 3, worker_flavor: cx2.48x96, tmm_replicas: 9, cneinstance_size: Tiny
```

What lands in the rendered `config.yaml` for the Small cluster:

```yaml
cluster:
  workers_per_zone: 2
  worker_flavor: bx2.8x32
bnk:
  tmm_replicas: 3
  cneinstance_size: Tiny
```

## Building the cluster from Git, or installing onto one you have

The three size overlays are written for the **hub** topology with
`cluster.create: true`: the `bnk-cluster` hook runs `cluster up --auto`, which
builds the VPC, the three subnets, the ROKS cluster of that size and its
Transit Gateway attachment, and then `bnk-up` installs BNK. Deleting the
Application later runs `bnk down` and — because the overlays set
`teardown.cluster: true` — `cluster down` as well.

To install a given size onto a cluster you already built (with roksbnkctl, the
console, or Terraform), keep the `tmmReplicas` line and switch the cluster
block:

```yaml
cluster:
  create: false
  name: my-existing-cluster
  registryCosName: my-existing-cluster-registry-cos   # if roksbnkctl built it
```

The worker flavour and count are then facts about the cluster rather than
inputs; roksbnkctl records them in `cluster-outputs.json` when it registers the
cluster.

## Two things that decide whether a new cluster comes up at all

- **Address prefix.** `config.cluster.vpc_cidr` must not overlap any VPC
  already attached to the Transit Gateway named in
  `config.resources.transit_gateway.existing`. Overlaps are not rejected by the gateway;
  they are silently black-holed. The size overlays use `10.252/16`,
  `10.253/16` and `10.254/16`; check them against your gateway before you sync.
- **Quota.** `doctor` (the `bnk-init` hook) prints VPCs-per-region and
  Transit-Gateways-per-account usage before anything is built. A Large cluster
  is nine `cx2.48x96` workers — check the vCPU quota too.

## Baseline

The BNK 2.4 IBM install guide itself describes a smaller shape: three
`bx2.16x64` workers (one per zone) with `tmmReplicas: 1`. roksbnkctl verifies
that one as well. It is the cheapest way to see BNK 2.4 come up:
`sizing.profile: baseline`.
