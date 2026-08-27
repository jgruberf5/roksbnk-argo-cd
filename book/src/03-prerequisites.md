# Prerequisites

## Argo CD

A working Argo CD with a user who can create `AppProject`s, `Application`s and
edit `argocd-cm` (or the `ArgoCD` CR under OpenShift GitOps). Any of:

| Distribution | Notes |
|---|---|
| Upstream Argo CD ≥ 3.3 | What this book uses (v3.5.1). Open source, Apache-2.0. `PreDelete` hooks — the "delete the Application to uninstall" path — arrived in 3.3. |
| Upstream Argo CD 2.x / 3.0–3.2 | Everything works except `PreDelete`; uninstall by setting `lifecycle: down` and syncing, and set `preDelete.enabled: false`. |
| Red Hat OpenShift GitOps | The operator-packaged Argo CD for the in-target topology. The chart's health check is applied through the `ArgoCD` CR (`bootstrap/openshift/argocd-cr.yaml`). |

Argo CD needs to reach the Git repository. This book uses a read-only **deploy
key** on a private GitHub repository; an HTTPS token or a public repository
work the same way.

## The runner image

`ghcr.io/jgruberf5/roksbnkctl-tools-runner:v1.58.0` — roksbnkctl with its
embedded Terraform, `terraform` 1.10, `helm`, `kubectl`, `oc`, `ibmcloud`,
`jq`. It is public. **roksbnkctl 1.58.0 or newer is required**; the chart
refuses to render an older tag and the init hook checks the binary's version.
For an air-gapped hub, mirror it and set `runner.image` in the overlay.

## IBM Cloud

- **An API key** with authority over VPC Infrastructure, Kubernetes Service
  (`containers-kubernetes`), Transit Gateway (if the workspace attaches one),
  IAM (the install creates a trusted profile and policies for the CNE
  controller) and Cloud Object Storage (read). It goes into the workspace's
  `bnk-secrets` Secret as `IBMCLOUD_API_KEY` — never into Git.
- **A ROKS cluster** (in-target or hub with `cluster.create: false`), or the
  permission to create one (hub with `cluster.create: true`). BNK 2.4 was
  verified on OpenShift 4.21 single-NIC clusters; the sizing chapter lists the
  flavours.
- **The F5 supply chain in a COS bucket**: the FAR pull-key tarball
  (`f5-far-auth-key.tgz` or the EA `non-ga-prod-pull-key.tgz`) and the
  subscription JWT (`subscription.jwt`). The overlay names the COS instance,
  bucket, region and both object keys.
- **Egress from wherever the hook Jobs run** to `iam.cloud.ibm.com`,
  `containers.cloud.ibm.com`, the COS endpoint, the ROKS API endpoint,
  `repo.f5.com` (or your mirror), `quay.io`, `charts.jetstack.io`, `ghcr.io`
  and `releases.hashicorp.com` (unless you pre-seed the Terraform plugin
  cache on the PVC).

## Storage

An RWO storage class for the workspace claim: `ibmc-vpc-block-10iops-tier` on
ROKS, `local-path` on k3s. The claim is created once and kept.

## Tools on your workstation

Only what you need to edit Git and run one bootstrap script over ssh: `git`,
`kubectl` (optional), `argocd` CLI (optional — the UI does everything), and for
the hub VSI appendix the `ibmcloud` CLI with the `is` and `tg` plugins. To
refresh the screenshots you need Node.js.

## The repository

Clone or fork `github.com/jgruberf5/roksbnk-argo-cd`. You will commit one small
values file per workspace and one `Application` (or an `ApplicationSet` entry).
Everything else — the chart, the health check, the AppProject — is already
there.
