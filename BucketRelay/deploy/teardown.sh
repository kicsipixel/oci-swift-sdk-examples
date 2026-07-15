#!/usr/bin/env bash
# Removes everything the BucketRelay deploy created, in dependency order.
# Leaves the compartment itself intact.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$here/config.env"
[ -f "$here/state.env" ] && source "$here/state.env"
OCI=(oci --profile "${OCI_CLI_PROFILE:-DEFAULT}"); [ -n "${OCI_CLI_AUTH:-}" ] && OCI+=(--auth "$OCI_CLI_AUTH")
R=(--region "$REGION"); HR=(--region "${HOME_REGION:-$REGION}")

echo "1) delete container instances (waiting for full delete so the VNIC is released)"
for id in $("${OCI[@]}" "${R[@]}" container-instances container-instance list --compartment-id "$COMPARTMENT_ID" \
    --query 'data.items[?"lifecycle-state"!=`DELETED`].id' --raw-output 2>/dev/null | tr -d '[],"'); do
  [ -n "$id" ] && echo "   deleting $id" && \
    "${OCI[@]}" "${R[@]}" container-instances container-instance delete --container-instance-id "$id" \
      --force --wait-for-state SUCCEEDED --max-wait-seconds 600 --wait-interval-seconds 15 2>/dev/null
done

echo "2) delete policy (home region) — looked up by name"
PID=$("${OCI[@]}" "${HR[@]}" iam policy list --compartment-id "$COMPARTMENT_ID" \
  --query "data[?name=='$POLICY_NAME'].id | [0]" --raw-output 2>/dev/null)
[ -n "${PID:-}" ] && [ "$PID" != "None" ] && "${OCI[@]}" "${HR[@]}" iam policy delete --policy-id "$PID" --force 2>/dev/null || echo "   (policy gone)"

echo "3) delete dynamic group (home region) — looked up by name"
DID=$("${OCI[@]}" "${HR[@]}" iam dynamic-group list \
  --query "data[?name=='$DG_NAME'].id | [0]" --raw-output 2>/dev/null)
[ -n "${DID:-}" ] && [ "$DID" != "None" ] && "${OCI[@]}" "${HR[@]}" iam dynamic-group delete --dynamic-group-id "$DID" --force 2>/dev/null || echo "   (dg gone)"

echo "4) empty + delete bucket (objects + pre-authenticated requests both block a bucket delete)"
for pid in $("${OCI[@]}" "${R[@]}" os preauth-request list --namespace "$NAMESPACE" --bucket-name "$BUCKET" \
    --query 'data[].id' --raw-output 2>/dev/null | tr -d '[],"'); do
  [ -n "$pid" ] && "${OCI[@]}" "${R[@]}" os preauth-request delete --namespace "$NAMESPACE" --bucket-name "$BUCKET" --par-id "$pid" --force 2>/dev/null
done
"${OCI[@]}" "${R[@]}" os object bulk-delete --namespace "$NAMESPACE" --bucket-name "$BUCKET" --force 2>/dev/null
"${OCI[@]}" "${R[@]}" os bucket delete --namespace "$NAMESPACE" --name "$BUCKET" --force 2>/dev/null

echo "5) delete subnet"
[ -n "${SUBNET_ID:-}" ] && "${OCI[@]}" "${R[@]}" network subnet delete --subnet-id "$SUBNET_ID" --force --wait-for-state TERMINATED 2>/dev/null

echo "6) clear route table (an IGW cannot be deleted while a route rule targets it)"
[ -n "${RT_ID:-}" ] && "${OCI[@]}" "${R[@]}" network route-table update --rt-id "$RT_ID" --route-rules '[]' --force 2>/dev/null

echo "7) delete internet gateway"
[ -n "${IGW_ID:-}" ] && "${OCI[@]}" "${R[@]}" network internet-gateway delete --ig-id "$IGW_ID" --force 2>/dev/null

echo "8) delete VCN (removes its default route table + security list + DHCP options)"
[ -n "${VCN_ID:-}" ] && "${OCI[@]}" "${R[@]}" network vcn delete --vcn-id "$VCN_ID" --force 2>/dev/null

rm -f "$here/state.env"
echo "Teardown done. (Delete the image from your registry separately if you want it gone.)"
