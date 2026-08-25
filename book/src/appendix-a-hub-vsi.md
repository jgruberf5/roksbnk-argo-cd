# Appendix A — Building the hub VSI

The screenshots in this book come from a hub: upstream Argo CD on a single-node
k3s VSI inside IBM Cloud, in its own VPC, attached to a Transit Gateway, with a
floating IP for the UI. `hack/vsi/` builds it from a clean slate, adapted from
roksbnkctl's Argo Workflows demo bootstrap.

## What it builds

- a VPC with a **manual address prefix** you choose (so the routed CIDR is
  exactly known and can be checked for overlap), one subnet, a public gateway
  (egress to IBM Cloud APIs, F5's registry, ghcr), and security-group rules
  for 22 and the Argo CD NodePort;
- one connection to the Transit Gateway — **by name or id** — verified
  `attached` before the VSI is created. IBM Cloud allows a VPC on **one**
  gateway; the script prints the API error verbatim if a second is attempted;
- a `bx2-4x16` Ubuntu 24.04 VSI whose cloud-init installs k3s and a pinned
  upstream Argo CD (`manifests/install.yaml`, server-side apply), exposes
  `argocd-server` on NodePort 30443, and installs the `argocd` CLI;
- a floating IP bound to the VSI's network interface.

The k3s API is never exposed. Everything after cloud-init runs over ssh.

## Build it

```bash
export IBMCLOUD_API_KEY=…
export HUB_STATE=$HOME/.cache/roksbnk-argo-cd/hub-state     # a Linux filesystem (not /mnt/c)
TGWS="bnkci-testing" HUB_REGION=us-south HUB_ZONE=us-south-1 HUB_CIDR=10.250.0.0/24 \
  bash hack/vsi/bootstrap-hub.sh
```

About ten minutes. The script is idempotent — it records ids under `HUB_STATE`
and skips what exists — and it checks `HUB_CIDR` against every VPC already on
the gateway before it creates anything:

```text
==> transit gateway bnkci-testing (33c59acf-…)
==> 10.250.0.0/24 does not overlap any VPC on the selected gateways
==> boot image ibm-ubuntu-24-04-4-minimal-amd64-6
==> created VPC bnk-hub-vpc with prefix 10.250.0.0/24
==> subnet + public gateway + inbound 22/30443 from 0.0.0.0/0
==> hub VPC attached to bnkci-testing (verified)
==> VSI bnk-hub-argocd requested
==> hub VSI private=10.250.0.4 floating=52.118.188.143
==> waiting for cloud-init (k3s + Argo CD 3.5.1)…
==> BOOTSTRAP COMPLETE — Argo CD 3.5.1 at https://52.118.188.143:30443 (admin / see hub.env)
```

`hub.env` holds the floating IP, the ssh key path, the Argo CD URL and the
initial admin password. Lock the security group down with
`ALLOWED_CIDR=<your ip>/32` if the hub is more than a demo.

## Wire it

```bash
set -a; source "$HUB_STATE/hub.env"; set +a
ssh-keygen -t ed25519 -N '' -f ~/.ssh/argocd-deploy-key
gh repo deploy-key add ~/.ssh/argocd-deploy-key.pub -R <org>/roksbnk-argo-cd --title "argocd-hub (read-only)"
GIT_DEPLOY_KEY=~/.ssh/argocd-deploy-key WORKSPACE=sm-cli bash hack/vsi/apply-hub.sh
```

`apply-hub.sh` performs Step 1 over ssh: the health check, the AppProject, the
repository Secret from the deploy key, the workspace namespace and
`bnk-secrets` (written with `printf`, no trailing newline), a controller
restart so the health check is live, and the Application from
`apps/<workspace>-application.yaml`.

Then sync from the UI, or:

```bash
ssh -i "$HUB_SSH_KEY_FILE" ubuntu@$HUB_FIP 'export KUBECONFIG=~/.kube/config; argocd --core app sync bnk-sm-cli'
```

## Reaching the target cluster

The hook Jobs on the hub reach the ROKS cluster's **public service endpoint**
with the admin kubeconfig roksbnkctl fetches — the Transit Gateway is not on
that path. It *is* on the path to a Harbor mirror or an F5 License Proxy VSI
in another VPC, which is why the hub sits in the fabric at all. For a
private-endpoint-only cluster, the cluster's VPC and the hub's VPC must be on
the same gateway with non-overlapping prefixes.

A note from building this one: the target cluster's VPC used the same
`10.241.0.0/18` prefixes as another VPC already on `bnkci-testing`, so it
could not join that gateway — one of the two things the sizing chapter warns
about. The hub attached to `bnkci-testing`; the cluster stayed on its own
gateway; the install used the public endpoint and never noticed.

## Tear it down

Delete the Applications first (their PreDelete hooks run `bnk down`), then:

```bash
bash hack/vsi/unbootstrap-hub.sh --yes
```

VSI, floating IP, the gateway connection, subnet, public gateway, VPC and the
ssh key are removed; the gateway itself is never touched.
