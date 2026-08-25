#!/usr/bin/env bash
# bootstrap-hub.sh — build the Argo CD hub from a clean slate: a VPC with a
# chosen address prefix, subnet, public gateway, security-group rules, one
# connection per Transit Gateway (by name OR id), and a VSI running k3s +
# upstream Argo CD behind a floating IP.
#
# Adapted from roksbnkctl/scripts/demos/lib/bootstrap-{services,argo}.sh:
# idempotent (ids recorded under $HUB_STATE, stale ids dropped), tolerant of the
# eventually-consistent VPC API, no Harbor (the connected BNK 2.4 path pulls
# from FAR), and no exposed k3s API — kubectl runs over ssh.
#
#   IBMCLOUD_API_KEY=… TGWS="bnkci-testing sm-cli-tgw" bash hack/vsi/bootstrap-hub.sh
#   set -a; source "$HUB_STATE/hub.env"; set +a
#
# Emits: HUB_VPC_ID HUB_SUBNET_ID HUB_VSI_ID HUB_FIP HUB_SSH_KEY_FILE
#        ARGOCD_URL ARGOCD_ADMIN_PASSWORD (initial admin password)
set -euo pipefail

: "${IBMCLOUD_API_KEY:?set IBMCLOUD_API_KEY}"
HUB_REGION="${HUB_REGION:-us-south}"
HUB_ZONE="${HUB_ZONE:-${HUB_REGION}-1}"
RESOURCE_GROUP="${RESOURCE_GROUP:-default}"
HUB_PREFIX="${HUB_PREFIX:-bnk-hub}"
HUB_CIDR="${HUB_CIDR:-10.250.0.0/24}"          # must not overlap any VPC on the gateways
TGWS="${TGWS:-bnkci-testing}"                   # space-separated names or ids
ALLOWED_CIDR="${ALLOWED_CIDR:-0.0.0.0/0}"       # who may reach ssh + the Argo CD UI
VSI_PROFILE="${VSI_PROFILE:-bx2-4x16}"
ARGOCD_VERSION="${ARGOCD_VERSION:-3.5.1}"
ARGOCD_NODEPORT="${ARGOCD_NODEPORT:-30443}"
K3S_CHANNEL="${K3S_CHANNEL:-stable}"
HUB_STATE="${HUB_STATE:-$HOME/.cache/roksbnk-argo-cd/hub-state}"   # a Linux filesystem
SSH_KEY_NAME="${SSH_KEY_NAME:-${HUB_PREFIX}-key}"
SSH_KEY_FILE="${SSH_KEY_FILE:-$HUB_STATE/${SSH_KEY_NAME}}"
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

mkdir -p "$HUB_STATE"; chmod 700 "$HUB_STATE"
say(){ echo "==> $*" >&2; }
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=20 -o ServerAliveInterval=15"

# The VPC API is eventually consistent: a create returns before the object is
# readable. Poll instead of assuming.
wait_readable(){ local i; for i in $(seq 1 30); do "$@" >/dev/null 2>&1 && return 0; sleep 2; done; "$@" >/dev/null; }
# Drop a recorded id whose resource no longer exists (a re-run after teardown).
stale_state(){ local f="$HUB_STATE/$1"; shift; [[ -f "$f" ]] || return 0; local id; id="$(cat "$f")"; [[ -n "$id" ]] && "$@" "$id" >/dev/null 2>&1 || { say "recorded $(basename "$f") is stale — will recreate"; rm -f "$f"; }; }

ibmcloud login --apikey "$IBMCLOUD_API_KEY" -r "$HUB_REGION" -g "$RESOURCE_GROUP" -q >/dev/null

# ── Transit gateways, by name or id ──────────────────────────────────────────
declare -a TGW_IDS=() TGW_NAMES=()
GW_JSON="$(ibmcloud tg gateways --output json)"
for t in $TGWS; do
  id="$(jq -r --arg t "$t" '.[] | select(.name==$t or .id==$t) | .id' <<<"$GW_JSON" | head -1)"
  [[ -n "$id" ]] || { echo "transit gateway '$t' not found (by name or id)" >&2; exit 1; }
  TGW_IDS+=("$id"); TGW_NAMES+=("$(jq -r --arg i "$id" '.[]|select(.id==$i)|.name' <<<"$GW_JSON")")
  say "transit gateway ${TGW_NAMES[-1]} ($id)"
done

# ── Overlap check: HUB_CIDR against every VPC already on those gateways ─────
# Done up front because a prefix conflict surfaces as a silent black hole hours
# later, not as an error at connection-create time.
python3 - "$HUB_CIDR" <<<"$(for id in "${TGW_IDS[@]}"; do ibmcloud tg connections "$id" --output json; done | jq -r '.[]?|select(.network_type=="vpc")|.network_id' | sort -u | while read -r crn; do reg="$(cut -d: -f6 <<<"$crn")"; vid="${crn##*:}"; ibmcloud target -r "$reg" -q >/dev/null 2>&1; ibmcloud is vpc-address-prefixes "$vid" --output json 2>/dev/null | jq -r --arg n "$(ibmcloud is vpc "$vid" --output json 2>/dev/null | jq -r .name)" '.[]|"\($n) \(.cidr)"'; done)" <<'PY' || exit 1
import ipaddress, sys
hub = ipaddress.ip_network(sys.argv[1])
bad = [l for l in sys.stdin.read().splitlines() if l.strip() and hub.overlaps(ipaddress.ip_network(l.split()[1]))]
if bad:
    print("HUB_CIDR %s overlaps: %s" % (hub, ", ".join(bad)), file=sys.stderr); sys.exit(1)
print("==> %s does not overlap any VPC on the selected gateways" % hub, file=sys.stderr)
PY
ibmcloud target -r "$HUB_REGION" -q >/dev/null

# ── SSH key (RSA: VPC rejects some ed25519 keys) ─────────────────────────────
if [[ ! -f "$SSH_KEY_FILE" ]]; then ssh-keygen -t rsa -b 4096 -N '' -f "$SSH_KEY_FILE" -C "$SSH_KEY_NAME" >/dev/null; say "generated $SSH_KEY_FILE"; fi
chmod 600 "$SSH_KEY_FILE"
ibmcloud is key "$SSH_KEY_NAME" >/dev/null 2>&1 || { ibmcloud is key-create "$SSH_KEY_NAME" @"${SSH_KEY_FILE}.pub" --resource-group-name "$RESOURCE_GROUP" >/dev/null; say "registered VPC key $SSH_KEY_NAME"; }

# ── Boot image, resolved at run time ─────────────────────────────────────────
VSI_IMAGE="${VSI_IMAGE:-$(ibmcloud is images --visibility public --output json | jq -r '[.[]|select(.status=="available" and (.name|test("ubuntu-24-04.*amd64")))]|sort_by(.name)|last|.name')}"
[[ -n "$VSI_IMAGE" && "$VSI_IMAGE" != null ]] || { echo "no Ubuntu 24.04 image" >&2; exit 1; }
say "boot image $VSI_IMAGE"

stale_state vpc_id     ibmcloud is vpc
stale_state subnet_id  ibmcloud is subnet
stale_state pgw_id     ibmcloud is public-gateway
stale_state vsi_id     ibmcloud is instance

# ── VPC with a MANUAL address prefix (so HUB_CIDR is exactly what routes) ────
if [[ ! -f "$HUB_STATE/vpc_id" ]]; then
  ibmcloud is vpc-create "${HUB_PREFIX}-vpc" --address-prefix-management manual --resource-group-name "$RESOURCE_GROUP" --output json | jq -r .id > "$HUB_STATE/vpc_id"
  wait_readable ibmcloud is vpc "$(cat "$HUB_STATE/vpc_id")"
  ibmcloud is vpc-address-prefix-create "${HUB_PREFIX}-prefix" "$(cat "$HUB_STATE/vpc_id")" "$HUB_ZONE" "$HUB_CIDR" >/dev/null
  say "created VPC ${HUB_PREFIX}-vpc with prefix $HUB_CIDR"
fi
VPC_ID="$(cat "$HUB_STATE/vpc_id")"
VPC_CRN="$(ibmcloud is vpc "$VPC_ID" --output json | jq -r .crn)"

if [[ ! -f "$HUB_STATE/subnet_id" ]]; then
  ibmcloud is subnet-create "${HUB_PREFIX}-subnet" "$VPC_ID" --zone "$HUB_ZONE" --ipv4-cidr-block "$HUB_CIDR" --resource-group-name "$RESOURCE_GROUP" --output json | jq -r .id > "$HUB_STATE/subnet_id"
  wait_readable ibmcloud is subnet "$(cat "$HUB_STATE/subnet_id")"
  ibmcloud is public-gateway-create "${HUB_PREFIX}-pgw" "$VPC_ID" "$HUB_ZONE" --resource-group-name "$RESOURCE_GROUP" --output json | jq -r .id > "$HUB_STATE/pgw_id"
  ibmcloud is subnet-update "$(cat "$HUB_STATE/subnet_id")" --pgw "$(cat "$HUB_STATE/pgw_id")" >/dev/null
  SG_ID="$(ibmcloud is vpc "$VPC_ID" --output json | jq -r .default_security_group.id)"
  for p in 22 "$ARGOCD_NODEPORT"; do ibmcloud is security-group-rule-add "$SG_ID" inbound tcp --port-min "$p" --port-max "$p" --remote "$ALLOWED_CIDR" >/dev/null || true; done
  say "subnet + public gateway + inbound 22/$ARGOCD_NODEPORT from $ALLOWED_CIDR"
fi
SUBNET_ID="$(cat "$HUB_STATE/subnet_id")"

# ── Attach to every gateway, and VERIFY ──────────────────────────────────────
# IBM Cloud allows a VPC on ONE transit gateway. Listing several in TGWS only
# makes sense for a multi-gateway account layout; the second attach fails with
# invalid_state and the reason is printed verbatim instead of a jq parse error.
[[ ${#TGW_IDS[@]} -le 1 ]] || say "note: a VPC may be attached to only one transit gateway — the first attach that succeeds wins"
for i in "${!TGW_IDS[@]}"; do
  gid="${TGW_IDS[$i]}"; gname="${TGW_NAMES[$i]}"
  cid="$(ibmcloud tg connections "$gid" --output json 2>/dev/null | jq -r --arg v "$VPC_ID" '.[]?|select(.network_id|contains($v))|.id' 2>/dev/null | head -1)"
  if [[ -z "$cid" ]]; then
    out="$(ibmcloud tg connection-create "$gid" --name "${HUB_PREFIX}-conn" --network-type vpc --network-id "$VPC_CRN" --output json 2>&1)" || true
    cid="$(jq -r '.id // empty' <<<"$out" 2>/dev/null || true)"
    [[ -n "$cid" ]] || { echo "could not attach hub VPC to $gname:" >&2; echo "$out" | sed 's/^/    /' >&2; exit 1; }
  fi
  for _ in $(seq 1 40); do [[ "$(ibmcloud tg connection "$gid" "$cid" --output json 2>/dev/null | jq -r '.status // empty')" == attached ]] && break; sleep 6; done
  [[ "$(ibmcloud tg connection "$gid" "$cid" --output json | jq -r .status)" == attached ]] || { echo "connection to $gname never reached 'attached'" >&2; exit 1; }
  echo "$gid $cid" >> "$HUB_STATE/tgw_conns"; sort -u -o "$HUB_STATE/tgw_conns" "$HUB_STATE/tgw_conns"
  say "hub VPC attached to $gname (verified)"
done

# ── Floating IP + VSI ────────────────────────────────────────────────────────
ibmcloud is floating-ip "${HUB_PREFIX}-fip" >/dev/null 2>&1 || ibmcloud is floating-ip-reserve "${HUB_PREFIX}-fip" --zone "$HUB_ZONE" --resource-group-name "$RESOURCE_GROUP" >/dev/null
HUB_FIP="$(ibmcloud is floating-ip "${HUB_PREFIX}-fip" --output json | jq -r .address)"

if [[ ! -f "$HUB_STATE/vsi_id" ]]; then
  CI="$HUB_STATE/argocd-hub-cloud-init.yaml"
  ARGOCD_VERSION="$ARGOCD_VERSION" K3S_CHANNEL="$K3S_CHANNEL" ARGOCD_NODEPORT="$ARGOCD_NODEPORT" \
    envsubst '${ARGOCD_VERSION} ${K3S_CHANNEL} ${ARGOCD_NODEPORT}' < "$HERE/argocd-hub-cloud-init.yaml.tmpl" > "$CI"
  ibmcloud is instance-create "${HUB_PREFIX}-argocd" "$VPC_ID" "$HUB_ZONE" "$VSI_PROFILE" "$SUBNET_ID" \
    --image "$VSI_IMAGE" --keys "$SSH_KEY_NAME" --resource-group-name "$RESOURCE_GROUP" --user-data "@$CI" --output json | jq -r .id > "$HUB_STATE/vsi_id"
  say "VSI ${HUB_PREFIX}-argocd requested"
fi
VSI_ID="$(cat "$HUB_STATE/vsi_id")"
VNI=""; for _ in $(seq 1 40); do VNI="$(ibmcloud is instance "$VSI_ID" --output json 2>/dev/null | jq -r '.primary_network_attachment.virtual_network_interface.id // empty')"; [[ -n "$VNI" ]] && break; sleep 10; done
[[ -n "$VNI" ]] || { echo "VSI never exposed a primary VNI" >&2; exit 1; }
ibmcloud is virtual-network-interface-floating-ip-add "$VNI" "${HUB_PREFIX}-fip" >/dev/null 2>&1 || true
HUB_PRIVATE_IP="$(ibmcloud is instance "$VSI_ID" --output json | jq -r '.primary_network_interface.primary_ip.address')"
say "hub VSI private=$HUB_PRIVATE_IP floating=$HUB_FIP"

V(){ ssh -i "$SSH_KEY_FILE" $SSH_OPTS ubuntu@"$HUB_FIP" "$@"; }
say "waiting for cloud-init (k3s + Argo CD $ARGOCD_VERSION)…"
ready=0; for _ in $(seq 1 100); do V 'test -f /var/lib/cloud/argocd-hub-ready' >/dev/null 2>&1 && { ready=1; break; }; sleep 15; done
[[ $ready == 1 ]] || { echo "hub VSI never became ready over ssh" >&2; exit 1; }
V 'kubectl -n argocd get pods --no-headers' >&2 || true
ADMIN_PW="$(V 'kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath={.data.password} | base64 -d')"

cat > "$HUB_STATE/hub.env" <<EOF
HUB_REGION=$HUB_REGION
HUB_VPC_ID=$VPC_ID
HUB_SUBNET_ID=$SUBNET_ID
HUB_VSI_ID=$VSI_ID
HUB_PRIVATE_IP=$HUB_PRIVATE_IP
HUB_FIP=$HUB_FIP
HUB_SSH_KEY_FILE=$SSH_KEY_FILE
ARGOCD_VERSION=$ARGOCD_VERSION
ARGOCD_URL=https://$HUB_FIP:$ARGOCD_NODEPORT
ARGOCD_ADMIN_PASSWORD=$ADMIN_PW
EOF
chmod 600 "$HUB_STATE/hub.env"
say "BOOTSTRAP COMPLETE — Argo CD $ARGOCD_VERSION at https://$HUB_FIP:$ARGOCD_NODEPORT (admin / see $HUB_STATE/hub.env)"
