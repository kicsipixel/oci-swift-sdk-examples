#!/usr/bin/env bash
# Creates the Container Instance running the BucketRelay image, waits for it to
# become ACTIVE, prints the public endpoint, and smoke-tests the REST API.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$here/config.env"
[ -f "$here/state.env" ] || { echo "Run ./1-provision.sh first (state.env missing)."; exit 1; }
source "$here/state.env"
OCI=(oci --profile "${OCI_CLI_PROFILE:-DEFAULT}"); [ -n "${OCI_CLI_AUTH:-}" ] && OCI+=(--auth "$OCI_CLI_AUTH")
R=(--region "$REGION")

echo "==> Building create spec"
python3 - "$COMPARTMENT_ID" "$AVAILABILITY_DOMAIN" "$SUBNET_ID" "$IMAGE" "$SHAPE" "$OCPUS" "$MEMORY_GBS" \
  "$NAMESPACE" "$BUCKET" "$REGION" "$here/.spec.json" <<'PY'
import json,sys
(comp,ad,subnet,image,shape,ocpus,mem,ns,bucket,region,out)=sys.argv[1:12]
spec={
 "compartmentId":comp,"availabilityDomain":ad,"displayName":"bucket-relay",
 "shape":shape,"shapeConfig":{"ocpus":float(ocpus),"memoryInGBs":float(mem)},
 "vnics":[{"displayName":"primary","subnetId":subnet,"isPublicIpAssigned":True}],
 # The image only needs the bucket name; region comes from the resource principal
 # and the namespace is auto-detected at runtime.
 "containers":[{"displayName":"bucket-relay","imageUrl":image,
   "environmentVariables":{"OCI_BUCKET":bucket}}],
 "containerRestartPolicy":"ALWAYS",
}
json.dump(spec,open(out,"w"))
PY

echo "==> Creating container instance"
INSTANCE_ID=$("${OCI[@]}" "${R[@]}" container-instances container-instance create \
  --from-json "file://$here/.spec.json" --raw-output --query 'data.id')
rm -f "$here/.spec.json"
echo "instance: $INSTANCE_ID"
echo "export INSTANCE_ID=\"$INSTANCE_ID\"" >> "$here/state.env"

echo "==> Waiting for ACTIVE..."
for i in $(seq 1 40); do
  ST=$("${OCI[@]}" "${R[@]}" container-instances container-instance get --container-instance-id "$INSTANCE_ID" --raw-output --query 'data."lifecycle-state"')
  echo "   [$i] $ST"
  [ "$ST" = "ACTIVE" ] && break
  [ "$ST" = "FAILED" ] && { "${OCI[@]}" "${R[@]}" container-instances container-instance get --container-instance-id "$INSTANCE_ID" --raw-output --query 'data."lifecycle-details"'; exit 1; }
  sleep 10
done

VNIC_ID=$("${OCI[@]}" "${R[@]}" container-instances container-instance get --container-instance-id "$INSTANCE_ID" --raw-output --query 'data.vnics[0]."vnic-id"')
PUBLIC_IP=$("${OCI[@]}" "${R[@]}" network vnic get --vnic-id "$VNIC_ID" --raw-output --query 'data."public-ip"')
BASE="http://$PUBLIC_IP:8080"

echo ""; echo "==> Endpoint: $BASE   (waiting for the image pull + server to come up)"
for i in $(seq 1 40); do curl -fsS -m 5 "$BASE/health" >/dev/null 2>&1 && break || sleep 8; done

echo "GET  /health   -> $(curl -fsS "$BASE/health")"
echo "PUT  /files/hello.txt"; curl -fsS -X PUT --data-binary "hello from BucketRelay" "$BASE/files/hello.txt"; echo
echo "GET  /files/hello.txt -> $(curl -fsS "$BASE/files/hello.txt")"
echo "GET  /files    -> $(curl -fsS "$BASE/files")"
echo ""
echo "Live at: $BASE   (public + unauthenticated — lock down or ./teardown.sh when done)"
