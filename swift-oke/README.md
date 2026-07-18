# swift-oke

A small [Hummingbird](https://github.com/hummingbird-project/hummingbird) REST service that reads a file from **OCI Object Storage** and returns its text — authenticating with **OKE Workload Identity**. It runs as a pod in an Oracle Container Engine for Kubernetes (OKE) cluster and uses **no API key and no config file**: the pod's Kubernetes service account *is* the identity, authorized by a condition-based OCI IAM policy.

## What it demonstrates

- **OKE Workload Identity** end-to-end with [`OCIKit`](https://github.com/iliasaz/oci-swift-sdk): `OKEWorkloadIdentitySigner.fromWorkloadIdentity()` exchanges the pod's projected service-account token for a resource principal session token (RPST) at the in-cluster *proxymux* endpoint, then signs Object Storage requests with it.
- **In-process custom-CA TLS**, the way the Java/Python/Go SDKs do it. The proxymux TLS certificate is signed by the in-cluster Kubernetes CA (not a public CA). The opt-in `OCIKitWorkloadIdentity` product pins that CA **in-process** via AsyncHTTPClient + NIOSSL (BoringSSL) — so there is **no `update-ca-certificates` step, no cluster CA install, nothing extra in the image**. It just reads the CA that Kubernetes already projects into every pod.

## Architecture

```mermaid
flowchart LR
  subgraph pod["OKE pod (swift-oke)"]
    app["Hummingbird app<br/>OCIKit + OCIKitWorkloadIdentity"]
    sa["/var/run/secrets/.../token<br/>/var/run/secrets/.../ca.crt"]
  end
  proxymux["proxymux<br/>KUBERNETES_SERVICE_HOST:12250"]
  os["OCI Object Storage"]

  app -- "POST podKey + Bearer SA-token<br/>(TLS pinned to cluster CA)" --> proxymux
  proxymux -- "RPST (ST$...)" --> app
  app -- "GET object, signed with RPST" --> os
  sa -. mounted .-> app
```

## Authentication flow

1. `OKEWorkloadIdentitySigner.fromWorkloadIdentity()` reads `KUBERNETES_SERVICE_HOST` and the auto-mounted service-account token + cluster CA.
2. It generates an ephemeral RSA key and `POST`s the public key (`podKey`) to `https://$KUBERNETES_SERVICE_HOST:12250/resourcePrincipalSessionTokens`, authenticated with the SA bearer token, **verifying the proxymux TLS cert against the cluster CA in-process**.
3. The proxymux returns an RPST; the signer signs OCI requests with `keyId = ST$<rpst>` and the ephemeral key, refreshing at the token's half-life.

```swift
import OCIKit
import OCIKitWorkloadIdentity

let signer = try await OKEWorkloadIdentitySigner.fromWorkloadIdentity()
let client = try ObjectStorageClient(region: region, signer: signer)
let data = try await client.getObject(
  namespaceName: ns, bucketName: "bucket-relay-bucket", objectName: "swift-oke-test.txt")
```

## REST API

| Method | Path            | Description                                        |
| ------ | --------------- | -------------------------------------------------- |
| GET    | `/health`       | Liveness (no OCI call).                            |
| GET    | `/`             | Service info.                                      |
| GET    | `/file`         | Read `OCI_OBJECT` (default `swift-oke-test.txt`).  |
| GET    | `/files/{name}` | Read any object in the bucket, returned as text.   |

Configuration (env, all optional): `OCI_BUCKET` (default `bucket-relay-bucket`), `OCI_OBJECT` (default `swift-oke-test.txt`), `OCI_REGION` (falls back to `OCI_RESOURCE_PRINCIPAL_REGION`), `OCI_NAMESPACE` (auto-detected if unset), `PORT` (default `8080`).

## Prerequisites (OCI side, one-time)

1. **Enhanced OKE cluster.** Workload identity requires an enhanced cluster (a non-enhanced cluster returns HTTP 403 "please ensure the cluster type is enhanced").
2. **A bucket + the test object.** In `bucket-relay-bucket`, upload an object named `swift-oke-test.txt` with some text (e.g. `Hello from OKE Workload Identity!`).
3. **An IAM policy** authorizing the workload. OKE Workload Identity does **not** use dynamic groups — you grant access with a **condition-based `any-user` policy** that matches the pod's `request.principal.*` attributes ([Oracle docs](https://docs.oracle.com/en-us/iaas/Content/ContEng/Tasks/contenggrantingworkloadaccesstoresources.htm)). Create it with the OCI CLI (replace the `<...>` placeholders — `BUCKET_COMPARTMENT` is the compartment holding the bucket, `CLUSTER_OCID` your cluster's OCID):

   ```bash
   oci iam policy create \
     --compartment-id <BUCKET_COMPARTMENT_OCID> \
     --name swift-oke-policy \
     --description "Allow the swift-oke workload to read bucket-relay-bucket" \
     --statements '[
       "Allow any-user to read objects in compartment id <BUCKET_COMPARTMENT_OCID> where all {request.principal.type = '\''workload'\'', request.principal.namespace = '\''default'\'', request.principal.service_account = '\''swift-oke'\'', request.principal.cluster_id = '\''<CLUSTER_OCID>'\'', target.bucket.name = '\''bucket-relay-bucket'\''}",
       "Allow any-user to read buckets in compartment id <BUCKET_COMPARTMENT_OCID> where all {request.principal.type = '\''workload'\'', request.principal.namespace = '\''default'\'', request.principal.service_account = '\''swift-oke'\'', request.principal.cluster_id = '\''<CLUSTER_OCID>'\''}"
     ]'
   ```

   Handy lookups: the bucket's compartment — `oci os bucket get --name bucket-relay-bucket --namespace <ns>` (or Console); your cluster's OCID — `oci ce cluster list --compartment-id <c>`.

> The condition attributes (`namespace`, `service_account`, `cluster_id`) must match the pod: namespace `default`, service account `swift-oke`, and your cluster's OCID.

## Build & push the image

The `Dockerfile` builds from the SDK as a **remote** dependency, so the container build can fetch it. Before building, point `Package.swift` at the pushed SDK (the checked-in default is a local path for development):

```swift
// Package.swift
.package(url: "https://github.com/iliasaz/oci-swift-sdk.git", branch: "main"),
```

Then build for your node-pool architecture and push to OCIR:

```bash
cd swift-oke
REGISTRY=<region-key>.ocir.io/<tenancy-namespace>   # e.g. fra.ocir.io/mytenancynamespace
docker build --platform linux/arm64 -t "$REGISTRY/swift-oke:latest" .   # or linux/amd64
docker login <region-key>.ocir.io                                       # user: <tenancy-namespace>/<user>, pass: auth token
docker push "$REGISTRY/swift-oke:latest"
```

## Deploy

Edit `deploy/swift-oke.yaml` — set the `image`, `OCI_REGION`, and (if your bucket differs) `OCI_BUCKET`/`OCI_OBJECT`.

The bundled Service is a **public OCI Load Balancer** tuned for a virtual-nodes cluster. On virtual nodes it only comes up healthy once the LB subnet security rules and the TLS secret exist — set those up first (next section). For an internal-only test, swap the Service for the minimal `ClusterIP` variant shown in the manifest and reach it in-cluster instead.

```bash
kubectl apply -f deploy/swift-oke.yaml
kubectl rollout status deploy/swift-oke
```

## Expose it publicly (HTTPS via an OCI Load Balancer)

Applying the manifest provisions a **flexible OCI Load Balancer** with its own public IP (distinct from the cluster's API-server endpoint on `:6443`, which never routes to your workloads), terminates **TLS at the LB** on 443, and forwards to the **pods** as backends. It works on a Quick-Create **virtual-nodes-only** cluster — but only once two things exist that OKE does *not* set up for you on virtual nodes: the **VCN security rules** and the **TLS secret**.

### How load balancing actually works on virtual nodes

Every virtual node carries the label `node.kubernetes.io/exclude-from-external-load-balancers: "true"`, so OKE never registers nodes as LB backends. Instead the **pods are the backends**, reached as `<pod-ip>:<NodePort>` — not `<pod-ip>:<targetPort>`. This works because **each pod on a virtual node runs its own kube-proxy** (inside the pod, not in `kube-system`): it serves the NodePort DNAT to the app on 8080, and the LB health check `HTTP GET /healthz` on port **10256**, both on the pod's own IP.

Because the node-registration path is disabled, the Service permanently emits `Warning ... UnAvailableLoadBalancer — There are no available nodes for LoadBalancer` events. On virtual nodes these are **cosmetic and expected** — the pod-backend path is what actually serves traffic.

Two things that look configurable here are not:

- **Pod backends need no annotation** — they are the built-in (and only) behavior on virtual nodes. The `oci.oraclecloud.com/oci-load-balancer-backend-policy: "pods"` annotation that circulates in forum posts appears in no OCI documentation, and we verified the backend registration is byte-for-byte identical with and without it.
- **Don't confuse this with OKE's documented ["pods as backends" feature](https://docs.oracle.com/en-us/iaas/Content/ContEng/Tasks/contengconfiguringloadbalancersnetworkloadbalancers-subtopic.htm)** (`oci-load-balancer.oraclecloud.com/backend-type: "pod"` + `allocateLoadBalancerNodePorts: false`), which targets `pod-ip:targetPort` with a custom app health check. That feature is **managed-nodes-only** ("supported on managed nodes, but not on virtual nodes") — on virtual nodes you get the `<pod-ip>:<NodePort>` + `/healthz:10256` model described above, and it works fine.

```mermaid
flowchart LR
  client["Internet client"]
  subgraph lb["OCI Load Balancer (public IP)"]
    l443["listener :443 (TLS)"]
    l80["listener :80"]
    hc["health checker"]
  end
  subgraph pod["swift-oke pod (virtual node)"]
    kp["kube-proxy<br/>NodePort + /healthz:10256"]
    app["Hummingbird app :8080"]
  end
  client -- "HTTPS 443 / HTTP 80" --> l443
  client --> l80
  l443 -- "decrypt, forward to pod-ip:NodePort" --> kp
  l80 --> kp
  kp -- "DNAT" --> app
  hc -- "GET /healthz on pod-ip:10256" --> kp
```

> `externalTrafficPolicy: Local` (client-IP preservation) is **not supported** on virtual nodes — keep the default `Cluster`.

### Security rules

OKE **never** manages LB security rules on virtual nodes (management mode is effectively `None`), so you create them yourself. The LB subnet must allow the listeners in and the traffic + health check out to the node/pod subnet; the node/pod subnet must allow that traffic + health check in:

| Seclist | Direction | Endpoint | Protocol / ports | Purpose |
| --- | --- | --- | --- | --- |
| LB subnet `10.0.20.0/24` | ingress | `0.0.0.0/0` | TCP 80 | HTTP listener |
| LB subnet `10.0.20.0/24` | ingress | `0.0.0.0/0` | TCP 443 | HTTPS listener |
| LB subnet `10.0.20.0/24` | egress | node CIDR `10.0.10.0/24` | TCP 30000-32767 | traffic to pod NodePorts |
| LB subnet `10.0.20.0/24` | egress | node CIDR `10.0.10.0/24` | TCP 10256 | **health check** to pods |
| node subnet `10.0.10.0/24` | ingress | LB CIDR `10.0.20.0/24` | TCP 30000-32767 | traffic from LB |
| node subnet `10.0.10.0/24` | ingress | LB CIDR `10.0.20.0/24` | TCP 10256 | health check from LB |

The CIDRs above are the Quick-Create wizard's defaults (LB subnet `oke-svclbsubnet-*` = `10.0.20.0/24`, node/pod subnet `oke-nodesubnet-*` = `10.0.10.0/24`). The script discovers those subnets by name and ensures all six rules idempotently — safe to re-run:

```bash
./deploy/lb-security-rules.sh <compartment-ocid> --profile <profile>
```

> ⚠️ **The gotcha that bites everyone:** the health-check **egress** rule must target the **node/pod** subnet, not the LB subnet. A wrong destination here is **invisible in the Service events** — the LB comes up, serves traffic for ~30 seconds after each reconcile, then the OCI health checker (blocked from reaching `:10256`) marks the backends unhealthy and the LB stops forwarding. "Works, then dies" almost always means this rule.

### Routing (verify only)

The Quick Create wizard also sets up the route tables correctly, so this is a **verify-only** step — only hand-built VCNs need to create these. Confirm with `oci network route-table list --compartment-id <compartment> --vcn-id <vcn-ocid>`:

| Subnet | Route table | Rule | Purpose |
| --- | --- | --- | --- |
| LB subnet `10.0.20.0/24` (public) | `oke-public-routetable-*` | `0.0.0.0/0` → Internet Gateway | makes the LB internet-reachable |
| node/pod subnet `10.0.10.0/24` (private) | `oke-private-routetable-*` | `0.0.0.0/0` → NAT Gateway | pods reach the internet (e.g. to pull images) |
| node/pod subnet `10.0.10.0/24` (private) | `oke-private-routetable-*` | `all-<region>-services-in-oracle-services-network` → Service Gateway | pods reach OCI services (proxymux, Object Storage) for workload identity |

The pod subnet must route out through the **NAT gateway** (not an internet gateway) plus the **service gateway**, per the [virtual-nodes network docs](https://docs.oracle.com/en-us/iaas/Content/ContEng/Tasks/contengnetworkconfig-virtualnodes.htm).

### TLS secret

The Service terminates TLS at the LB using a Kubernetes TLS secret named `swift-oke-tls`. For a quick start, self-sign a cert:

```bash
openssl req -x509 -newkey rsa:2048 -keyout tls.key -out tls.crt -days 365 -nodes \
  -subj "/CN=swift-oke" -addext "subjectAltName=DNS:swift-oke"
kubectl create secret tls swift-oke-tls --cert=tls.crt --key=tls.key
```

A self-signed cert means clients must use `curl -k` (or trust the cert).

**Rotating or replacing the certificate — the secret name must change.** The cloud-controller creates the OCI LB certificate *named after the secret*, and LB certificates are **immutable by name**: updating the secret's contents in place never changes what the LB serves. To rotate (e.g. to add the LB's public IP to the SAN once you know it, or to swap in a real CA-issued cert for a DNS name pointing at the LB), create a **new** secret and repoint the annotation — the listener switches with no downtime:

```bash
openssl req -x509 -newkey rsa:2048 -keyout tls.key -out tls.crt -days 365 -nodes \
  -subj "/CN=swift-oke" -addext "subjectAltName=IP:<LB_PUBLIC_IP>,DNS:swift-oke"
kubectl create secret tls swift-oke-tls-2 --cert=tls.crt --key=tls.key
kubectl annotate svc swift-oke \
  service.beta.kubernetes.io/oci-load-balancer-tls-secret=swift-oke-tls-2 --overwrite
```

### Deploy and verify

```bash
kubectl apply -f deploy/swift-oke.yaml
kubectl get svc swift-oke -w        # wait for EXTERNAL-IP to leave <pending>
```

Once an EXTERNAL-IP is assigned:

```bash
LB=<external-ip>
curl    http://$LB/health                    # -> ok
curl -k https://$LB/health                    # -> ok
curl -k https://$LB/file                       # -> text of swift-oke-test.txt (Object Storage via workload identity)
curl -k https://$LB/files/some-other-object.txt
```

If `/file` returns the file's text, the pod authenticated to Object Storage purely through its Kubernetes identity — no keys, no config.

Confirm the OCI side is healthy. Backends should be registered as `<pod-ip>:<NodePort>` with a health check of `HTTP /healthz:10256`, and the backend set should read **OK** — that is the correct working state, not a bug:

```bash
# 1. Find your LB by the public IP (the EXTERNAL-IP from kubectl):
oci lb load-balancer list --compartment-id <compartment> --profile <profile> \
  --query 'data[].{name:"display-name", id:id, ips:"ip-addresses"}'

# 2. With the LB OCID, list its backend sets (typically TCP-80 and TCP-443) and check health:
oci lb backend-set list --load-balancer-id <lb-ocid> --profile <profile> --query 'data[].name'
oci lb backend-set-health get --load-balancer-id <lb-ocid> \
  --backend-set-name <name> --profile <profile>          # -> "status": "OK"
```

### Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| `UnAvailableLoadBalancer — There are no available nodes for LoadBalancer` events | Cosmetic on virtual nodes — the node-registration path is disabled by the `exclude-from-external-load-balancers` label | Ignore; the pods-as-backends path serves traffic |
| LB serves for ~30s then returns empty replies, repeatedly | Health-check **egress** rule missing or pointed at the wrong subnet, so the OCI health checker can't reach `:10256` | Point LB-subnet egress TCP 10256 at the **node/pod** CIDR; re-run `lb-security-rules.sh` |
| `409 ... Token collision` on rapid Service create/delete | The OCI cloud-controller is mid-reconcile | Let the reconcile settle (~30-60s), then re-apply |
| Updated the TLS secret but the LB serves the old certificate | OCI LB certificates are immutable by name; the CCM names them after the secret | Create a secret under a **new** name and update the `oci-load-balancer-tls-secret` annotation |
| `kubectl port-forward` / `kubectl exec` return `501 not implemented` | Not supported on virtual nodes | Test via the LB, or run a one-shot curl `Pod`/`Job` hitting the ClusterIP `http://swift-oke.default.svc.cluster.local` and read `kubectl logs` (`logs` works on virtual nodes; `port-forward`/`exec` do not) |

### References

- [Comparing Virtual Nodes with Managed Nodes](https://docs.oracle.com/en-us/iaas/Content/ContEng/Tasks/contengcomparingvirtualwithmanagednodes_topic.htm) — pods as backends, per-pod kube-proxy
- [Network resource configuration for virtual nodes](https://docs.oracle.com/en-us/iaas/Content/ContEng/Tasks/contengnetworkconfig-virtualnodes.htm) — the exact security rules
- [Specifying load balancer / network load balancer annotations](https://docs.oracle.com/en-us/iaas/Content/ContEng/Tasks/contengconfiguringloadbalancersnetworkloadbalancers-subtopic.htm) — pods-as-backends annotations
- [Getting started: best practices for OKE virtual nodes](https://blogs.oracle.com/cloud-infrastructure/getting-started-best-practices-oke-virtual-nodes)

## Notes

- ⚠️ **SDK dependency:** the checked-in `Package.swift` uses a local `path:` reference for developing against an unmerged SDK branch. Switch it to the remote `branch: "main"` (or a tagged release) before `docker build` — the sibling SDK checkout is not in the image build context.
- The workload-identity transport lives in the **opt-in** `OCIKitWorkloadIdentity` product. Consumers who don't use OKE never pull the swift-nio dependency graph.
- Region is read from `OCI_REGION`, falling back to the resource-principal region (`OCI_RESOURCE_PRINCIPAL_REGION`) if the deployment sets it; the namespace is auto-detected via `getNamespace()`.
