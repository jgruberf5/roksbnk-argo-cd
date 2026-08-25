#!/usr/bin/env bash
# unbootstrap-hub.sh — destroy what bootstrap-hub.sh created: VSI, floating IP,
# the hub VPC's gateway connections (never the gateways), public gateway,
# subnet, VPC, and the VPC SSH key. Delete the Applications first so their
# PreDelete hooks run `bnk down` — this script cannot do that once the node is gone.
#
#   IBMCLOUD_API_KEY=… bash hack/vsi/unbootstrap-hub.sh --yes
set -uo pipefail
: "${IBMCLOUD_API_KEY:?set IBMCLOUD_API_KEY}"
HUB_REGION="${HUB_REGION:-us-south}"; RESOURCE_GROUP="${RESOURCE_GROUP:-default}"; HUB_PREFIX="${HUB_PREFIX:-bnk-hub}"
HUB_STATE="${HUB_STATE:-$HOME/.cache/roksbnk-argo-cd/hub-state}"; SSH_KEY_NAME="${SSH_KEY_NAME:-${HUB_PREFIX}-key}"
say(){ echo "==> $*" >&2; }
[[ "${1:-}" == "--yes" ]] || { printf "Delete the %s hub (VSI, FIP, VPC, key)? [y/N]: " "$HUB_PREFIX" >&2; read -r a; [[ "$a" =~ ^[yY] ]] || exit 1; }
ibmcloud login --apikey "$IBMCLOUD_API_KEY" -r "$HUB_REGION" -g "$RESOURCE_GROUP" -q >/dev/null || exit 1

id="$(ibmcloud is instances --output json | jq -r --arg n "${HUB_PREFIX}-argocd" '.[]|select(.name==$n)|.id')"
[[ -n "$id" ]] && { ibmcloud is instance-delete "$id" -f >/dev/null && say "deleting VSI"; for _ in $(seq 1 60); do ibmcloud is instance "$id" >/dev/null 2>&1 || break; sleep 10; done; }
fid="$(ibmcloud is floating-ip "${HUB_PREFIX}-fip" --output json 2>/dev/null | jq -r '.id // empty')"; [[ -n "$fid" ]] && ibmcloud is floating-ip-release "$fid" -f >/dev/null && say "released floating ip"
VPC_ID="$(ibmcloud is vpcs --output json | jq -r --arg n "${HUB_PREFIX}-vpc" '.[]|select(.name==$n)|.id')"
if [[ -n "$VPC_ID" ]]; then
  for gid in $(ibmcloud tg gateways --output json | jq -r '.[].id'); do
    for cid in $(ibmcloud tg connections "$gid" --output json 2>/dev/null | jq -r --arg v "$VPC_ID" '.[]?|select(.network_id|contains($v))|.id'); do
      ibmcloud tg connection-delete "$gid" "$cid" -f >/dev/null && say "detached hub VPC from gateway $gid"
    done
  done
  sleep 20
  for sid in $(ibmcloud is subnets --output json | jq -r --arg v "$VPC_ID" '.[]|select(.vpc.id==$v)|.id'); do ibmcloud is subnet-delete "$sid" -f >/dev/null && say "deleted subnet"; done
  sleep 10
  for pid in $(ibmcloud is public-gateways --output json | jq -r --arg v "$VPC_ID" '.[]|select(.vpc.id==$v)|.id'); do ibmcloud is public-gateway-delete "$pid" -f >/dev/null && say "deleted public gateway"; done
  sleep 5
  ibmcloud is vpc-delete "$VPC_ID" -f >/dev/null && say "deleted VPC"
fi
kid="$(ibmcloud is keys --output json | jq -r --arg n "$SSH_KEY_NAME" '.[]|select(.name==$n)|.id')"; [[ -n "$kid" ]] && ibmcloud is key-delete "$kid" -f >/dev/null && say "deleted VPC key $SSH_KEY_NAME"
rm -f "$HUB_STATE"/{vpc_id,subnet_id,pgw_id,vsi_id,tgw_conns,hub.env}
say "hub removed"
