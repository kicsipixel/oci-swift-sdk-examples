#!/usr/bin/env bash
# Provisions the OCI resources BucketRelay needs:
#   - a VCN + public subnet + internet gateway (so the container can reach OCI + be reached)
#   - a security-list rule opening TCP 8080
#   - an Object Storage bucket
#   - a dynamic group matching container instances in the compartment
#   - a policy granting that dynamic group read/write on objects in the bucket
# Writes the derived values (subnet, namespace, ...) to deploy/state.env for the next steps.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -f "$here/config.env" ] || { echo "Copy config.env.example to config.env and fill it in."; exit 1; }
source "$here/config.env"
OCI=(oci --profile "${OCI_CLI_PROFILE:-DEFAULT}"); [ -n "${OCI_CLI_AUTH:-}" ] && OCI+=(--auth "$OCI_CLI_AUTH")
R=(--region "$REGION"); HR=(--region "${HOME_REGION:-$REGION}")   # IAM writes go to the HOME region

echo "==> Object Storage namespace"
NAMESPACE=$("${OCI[@]}" "${R[@]}" os ns get --compartment-id "$COMPARTMENT_ID" --raw-output --query 'data')

echo "==> Compartment name (for the policy statement)"
COMPARTMENT_NAME=$("${OCI[@]}" "${HR[@]}" iam compartment get --compartment-id "$COMPARTMENT_ID" --raw-output --query 'data.name')

echo "==> VCN"
VCN_JSON=$("${OCI[@]}" "${R[@]}" network vcn create --compartment-id "$COMPARTMENT_ID" \
  --display-name "${PREFIX}-vcn" --cidr-blocks '["10.0.0.0/16"]' --dns-label "brelay" \
  --query 'data.{vcn:id,rt:"default-route-table-id",sl:"default-security-list-id"}' --output json)
VCN_ID=$(echo "$VCN_JSON" | python3 -c 'import json,sys;print(json.load(sys.stdin)["vcn"])')
RT_ID=$(echo "$VCN_JSON" | python3 -c 'import json,sys;print(json.load(sys.stdin)["rt"])')
SL_ID=$(echo "$VCN_JSON" | python3 -c 'import json,sys;print(json.load(sys.stdin)["sl"])')

echo "==> Internet gateway + default route"
IGW_ID=$("${OCI[@]}" "${R[@]}" network internet-gateway create --compartment-id "$COMPARTMENT_ID" \
  --vcn-id "$VCN_ID" --is-enabled true --display-name "${PREFIX}-igw" --raw-output --query 'data.id')
"${OCI[@]}" "${R[@]}" network route-table update --rt-id "$RT_ID" --force \
  --route-rules "[{\"cidrBlock\":\"0.0.0.0/0\",\"networkEntityId\":\"$IGW_ID\"}]" >/dev/null

echo "==> Open TCP 8080 on the security list (preserving existing rules)"
"${OCI[@]}" "${R[@]}" network security-list get --security-list-id "$SL_ID" \
  --query 'data."ingress-security-rules"' --output json > "$here/.ingress.json"
python3 - "$here/.ingress.json" "$here/.ingress-new.json" <<'PY'
import json,sys
cur=json.load(open(sys.argv[1]))
def norm(r):
    o={"protocol":r["protocol"],"source":r.get("source"),"sourceType":r.get("source-type","CIDR_BLOCK"),"isStateless":r.get("is-stateless",False)}
    for k_api,k_out in (("tcp-options","tcpOptions"),("udp-options","udpOptions"),("icmp-options","icmpOptions")):
        if r.get(k_api): o[k_out]=r[k_api]
    if r.get("description"): o["description"]=r["description"]
    return {k:v for k,v in o.items() if v is not None}
rules=[norm(r) for r in cur]
rules.append({"protocol":"6","source":"0.0.0.0/0","sourceType":"CIDR_BLOCK","isStateless":False,
              "tcpOptions":{"destinationPortRange":{"min":8080,"max":8080}},"description":"bucket-relay 8080"})
json.dump(rules,open(sys.argv[2],"w"))
PY
"${OCI[@]}" "${R[@]}" network security-list update --security-list-id "$SL_ID" --force \
  --ingress-security-rules "file://$here/.ingress-new.json" >/dev/null
rm -f "$here/.ingress.json" "$here/.ingress-new.json"

echo "==> Public subnet"
SUBNET_ID=$("${OCI[@]}" "${R[@]}" network subnet create --compartment-id "$COMPARTMENT_ID" \
  --vcn-id "$VCN_ID" --cidr-block "10.0.1.0/24" --display-name "${PREFIX}-subnet" \
  --route-table-id "$RT_ID" --security-list-ids "[\"$SL_ID\"]" --dns-label "brelay" \
  --prohibit-public-ip-on-vnic false --raw-output --query 'data.id')

echo "==> Bucket"
"${OCI[@]}" "${R[@]}" os bucket create --namespace "$NAMESPACE" --compartment-id "$COMPARTMENT_ID" \
  --name "$BUCKET" >/dev/null || echo "   (bucket may already exist)"

echo "==> Dynamic group (matches container instances in this compartment) — HOME region"
"${OCI[@]}" "${HR[@]}" iam dynamic-group create --name "$DG_NAME" \
  --description "Container instances in $COMPARTMENT_NAME (BucketRelay)" \
  --matching-rule "ALL {resource.type='computecontainerinstance', resource.compartment.id='$COMPARTMENT_ID'}" \
  >/dev/null || echo "   (dynamic group may already exist)"

echo "==> Policy (RP read/write on objects in the bucket's compartment) — HOME region"
"${OCI[@]}" "${HR[@]}" iam policy create --compartment-id "$COMPARTMENT_ID" --name "$POLICY_NAME" \
  --description "Lets BucketRelay container instances use the bucket via Resource Principal" \
  --statements "[\"Allow dynamic-group $DG_NAME to manage objects in compartment $COMPARTMENT_NAME\",\"Allow dynamic-group $DG_NAME to read buckets in compartment $COMPARTMENT_NAME\"]" \
  >/dev/null || echo "   (policy may already exist)"

cat > "$here/state.env" <<EOF
export NAMESPACE="$NAMESPACE"
export VCN_ID="$VCN_ID"
export RT_ID="$RT_ID"
export SL_ID="$SL_ID"
export IGW_ID="$IGW_ID"
export SUBNET_ID="$SUBNET_ID"
export COMPARTMENT_NAME="$COMPARTMENT_NAME"
EOF

echo ""
echo "Provisioned. Wrote deploy/state.env:"
cat "$here/state.env"
echo ""
echo "Next: ./2-build-and-push.sh   then   ./3-deploy.sh"
