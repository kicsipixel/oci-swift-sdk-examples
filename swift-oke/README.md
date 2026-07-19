# swift-oke

A small [Hummingbird](https://github.com/hummingbird-project/hummingbird) REST service that reads a file from **OCI Object Storage** and returns its text — authenticating with **OKE Workload Identity**. It runs as a pod in an Oracle Container Engine for Kubernetes (OKE) cluster and uses **no API key and no config file**: the pod's Kubernetes service account *is* the identity, authorized by a condition-based OCI IAM policy.

## What it demonstrates

- **OKE Workload Identity** end-to-end with [`OCIKit`](https://github.com/iliasaz/oci-swift-sdk): `OKEWorkloadIdentitySigner.fromWorkloadIdentity()` exchanges the pod's projected service-account token for a resource principal session token (RPST) at the in-cluster *proxymux* endpoint, then signs Object Storage requests with it.
- **In-process custom-CA TLS**. The proxymux TLS certificate is signed by the in-cluster Kubernetes CA (not a public CA). The opt-in `OCIKitWorkloadIdentity` product pins that CA **in-process** via AsyncHTTPClient + NIOSSL (BoringSSL) — so there is **no `update-ca-certificates` step, no cluster CA install, nothing extra in the image**. It just reads the CA that Kubernetes already projects into every pod.

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

The bundled Service is a **public OCI Load Balancer** tuned for a virtual-nodes cluster — this is **Option B** in the next section, and it needs the LB subnet security rules (and a TLS secret) before it serves cleanly. If you plan to use **Option A** (a real Let's Encrypt cert via ingress-nginx, recommended), or just want an internal-only test, swap this Service for the minimal `ClusterIP` variant shown in the manifest and reach the app in-cluster instead. Either way, read *Expose it publicly* next before wiring up TLS.

```bash
kubectl apply -f deploy/swift-oke.yaml
kubectl rollout status deploy/swift-oke
```

> The irony isn't lost on us: this example is nominally about **Workload Identity** — running a Swift container on OKE and letting it reach other OCI services with no keys and no config — yet most of this page is about coaxing OKE's networking into letting anyone *reach* the container in the first place. That ratio is a faithful reflection of the lived experience.

## Expose it publicly (HTTPS)

Two ways to get a public HTTPS URL, both fronted by a **flexible OCI Load Balancer** with its own public IP (distinct from the cluster's API-server endpoint on `:6443`, which never routes to your workloads):

- **Option A (recommended): a real Let's Encrypt certificate** via ingress-nginx + cert-manager. TLS terminates inside the cluster, and certificates **auto-renew** with no manual steps and no `-k`. The OCI LB only passes TCP through, so nothing terminates TLS on OCI — which sidesteps the immutable-LB-certificate problem of the other option.
- **Option B: TLS terminated at the OCI Load Balancer** itself. No extra components, but you manage the certificate yourself — self-signed, or a real one you rotate by hand.

Either way the same virtual-nodes pieces sit underneath, so the next three sections — **how load balancing works**, **security rules**, and **routing** — apply to both. Read those first, then jump to Option A or Option B.

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

Option A works the same way, one layer out: the OCI LB's backends are then the **ingress-nginx** pods (still `<pod-ip>:<NodePort>` with `/healthz:10256`), and nginx routes to the swift-oke ClusterIP Service inside the cluster.

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

### Option A (recommended): a real certificate with ingress-nginx + cert-manager + Let's Encrypt

TLS terminates inside the cluster at **ingress-nginx**, and **cert-manager** obtains and auto-renews a real **Let's Encrypt** certificate over HTTP-01. The OCI LB fronting the ingress-nginx Service only passes TCP 80/443 through, so **nothing terminates TLS on OCI** — and the immutable-LB-certificate gotcha simply doesn't exist here.

Here's the whole path (the shared diagram earlier zooms into the kube-proxy/NodePort detail on one pod; this one is the map):

```mermaid
flowchart LR
  client["Internet client"]
  le["Let's Encrypt<br/>(ACME CA)"]

  subgraph vcn["VCN"]
    subgraph lbnet["public LB subnet — 10.0.20.0/24"]
      lb["OCI Load Balancer<br/>reserved public IP<br/>TCP 80/443 pass-through, no TLS"]
    end
    subgraph podnet["private node/pod subnet — 10.0.10.0/24"]
      nginx["ingress-nginx pod<br/>terminates TLS · routes by host"]
      app["swift-oke pod :8080<br/>(ClusterIP service)"]
      cm["cert-manager"]
      sec[["secret: swift-oke-le-tls"]]
    end
  end

  client -->|"HTTPS :443"| lb
  lb -->|"pod-ip:NodePort"| nginx
  nginx -->|"ClusterIP :80 → app :8080"| app

  le -.->|"HTTP-01 GET /.well-known :80"| lb
  lb -.->|":80 → pod-ip:NodePort"| nginx
  nginx -.->|"route challenge to solver"| cm
  cm -.->|"renew"| sec
  sec -.->|"hot-reload"| nginx
  lb -.->|"health check → pod-ip:10256"| nginx
```

Solid arrows are request traffic; dashed arrows are the certificate machinery and health checks. Routing (see *Routing* above): the LB subnet reaches the internet via an Internet Gateway, the pod subnet egresses via NAT + Service gateways.

**1. Reserve a public IP** so the address — and the DNS name and certificates bound to it — survive Service/LB recreation:

```bash
oci network public-ip create --compartment-id <compartment> \
  --lifetime RESERVED --display-name swift-oke-ingress-ip --profile <profile>
# note the assigned "ip-address", e.g. 137.131.40.124 (free while it stays assigned)
```

**2. Install ingress-nginx, patched for virtual nodes _before_ it creates its LB.** Applying the manifest unpatched provisions a throwaway LB with an ephemeral IP and the unsupported `Local` policy, which then has to be recreated — so edit first, apply second:

```bash
curl -sL https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.15.1/deploy/static/provider/cloud/deploy.yaml \
  -o ingress-nginx.yaml
```

In `ingress-nginx.yaml`, find the one `Service` named `ingress-nginx-controller` and set these fields on it:

```yaml
metadata:
  annotations:
    service.beta.kubernetes.io/oci-load-balancer-security-list-management-mode: "None"
    service.beta.kubernetes.io/oci-load-balancer-shape: "flexible"
    service.beta.kubernetes.io/oci-load-balancer-shape-flex-min: "10"
    service.beta.kubernetes.io/oci-load-balancer-shape-flex-max: "100"
spec:
  loadBalancerIP: <reserved-ip>          # from step 1 — pins the LB to the reserved IP
  externalTrafficPolicy: Cluster          # manifest ships "Local", which is unsupported on virtual nodes
```

Then apply and wait for the LB to take the reserved IP:

```bash
kubectl apply -f ingress-nginx.yaml
kubectl -n ingress-nginx get svc ingress-nginx-controller -w   # EXTERNAL-IP -> <reserved-ip>
```

**3. Ensure the security rules.** They're subnet-scoped, so the same six rules from Option B's script already cover the ingress LB — run it if you haven't:

```bash
./deploy/lb-security-rules.sh <compartment-ocid> --profile <profile>
```

**4. Install cert-manager:**

```bash
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.21.0/cert-manager.yaml
kubectl -n cert-manager rollout status deploy/cert-manager-webhook
```

ingress-nginx and cert-manager run as ordinary pods on virtual nodes; their images are multi-arch, so arm64 nodes are fine.

**5. Point the swift-oke Service at ClusterIP.** Option A fronts the app with the Ingress, so swift-oke needs only the in-cluster `ClusterIP` Service (the commented variant in `deploy/swift-oke.yaml`, port 80 → 8080), not the LoadBalancer one. If you previously applied the LB Service, switching it to ClusterIP deletes that direct LB automatically — leaving exactly one LB, the ingress one.

**6. Issue the certificate.** Fill `<ACME_EMAIL>` and `<INGRESS_HOST>` in `deploy/ingress-letsencrypt.yaml`, then apply:

```bash
kubectl apply -f deploy/ingress-letsencrypt.yaml
```

For `<INGRESS_HOST>`, [sslip.io](https://sslip.io) gives zero-setup DNS — `swift-oke.<reserved-ip-with-dashes>.sslip.io` resolves straight to the reserved IP (e.g. `swift-oke.137-131-40-124.sslip.io`), so no domain ownership is needed. For your own domain, set the host to it and point an A record at the reserved IP.

**7. Verify** — a real, fully verified certificate (note: no `-k`):

```bash
HOST=swift-oke.137-131-40-124.sslip.io
kubectl get certificate swift-oke-le-tls -w    # wait for READY=True (~1-2 min the first time)
curl    https://$HOST/health                   # -> ok  (full chain verified)
curl    https://$HOST/file                      # -> object text, read via workload identity
curl -I http://$HOST/                           # -> 308 redirect to https (nginx does this automatically)
```

cert-manager renews `swift-oke-le-tls` well before expiry and nginx hot-reloads it — there is no LB certificate to rotate, so the Option B immutable-cert dance never applies.

#### Why not terminate TLS at the OCI Load Balancer?

The OCI LB *can* terminate TLS — that's exactly what Option B does. The hard part is getting a **Let's Encrypt** certificate into it and keeping it there: LE certs expire after 90 days and want renewing about every 60, so "set it once" isn't an option. Three things make LB termination the wrong default here:

1. **The immutable-certificate behavior fights cert-manager.** As Option B describes, the CCM names the LB certificate after the Kubernetes secret and LB certs are **immutable by name** — but cert-manager's entire model is "renew the same secret in place." Point it at the LB and it would dutifully rewrite a secret the LB never re-reads, leaving the listener serving the *expired* cert. Automating it means building bespoke rename-and-reannotate glue whose failure mode is "site down with an expired cert two months from now." With nginx, the LB never sees the cert: cert-manager renews the secret and nginx hot-reloads it.
2. **sslip.io forces HTTP-01, and HTTP-01 needs path routing.** With no domain of your own, DNS-01 is off the table — sslip.io is a static resolver with no TXT records and no zone you control. That leaves HTTP-01, which serves a token at `http://<host>/.well-known/acme-challenge/…`. But with the plain LB Service, port 80 goes straight to the Swift app, so *something* has to route `/.well-known` to a challenge solver — and that something is an ingress controller (cert-manager's HTTP-01 solver is built to inject routes into one). No domain → sslip.io → HTTP-01 only → you need an ingress anyway.
3. **OCI has no managed public-certificate service.** AWS has ACM and GCP has managed certs that issue and self-renew right on the load balancer; OCI Certificates only issues from *your own private CA* (not browser-trusted), and public certs must be imported by hand with no ACME integration. If OCI had an ACM equivalent, terminating at the LB would be the obvious call.

What you trade: two extra in-cluster components (ingress-nginx, cert-manager) and one extra proxy hop. What you get: hands-off cert automation, an automatic HTTP→HTTPS redirect, and one LB that can front many services. The cost is identical — still exactly one load balancer.

> **With a real domain in a DNS zone you control** (e.g. OCI DNS), DNS-01 becomes available and argument #2 disappears — LE-at-the-LB is then genuinely *feasible*. But you'd still be writing the renewal glue for #1, which is why the boring cert-manager + ingress stack stays the default recommendation.

### Option B: TLS terminated at the OCI Load Balancer

No ingress controller or cert-manager: the OCI LB terminates TLS directly using a Kubernetes TLS secret, and you own the certificate lifecycle. Apply the LoadBalancer Service in `deploy/swift-oke.yaml` (its default) and give it a cert.

```mermaid
flowchart LR
  client["Internet client"]
  ccm["OCI cloud-controller<br/>(CCM)"]
  sec[["k8s secret: swift-oke-tls"]]

  subgraph vcn["VCN"]
    subgraph lbnet["public LB subnet — 10.0.20.0/24"]
      lb["OCI Load Balancer<br/>listener :443 terminates TLS<br/>serves the OCI LB certificate"]
    end
    subgraph podnet["private node/pod subnet — 10.0.10.0/24"]
      subgraph pod["swift-oke pod"]
        kp["kube-proxy<br/>NodePort DNAT + /healthz:10256"]
        app["app :8080"]
      end
    end
  end

  client -->|"HTTPS :443 (TLS)"| lb
  lb -->|"decrypt → pod-ip:NodePort"| kp
  kp -->|"DNAT"| app
  lb -.->|"health check → pod-ip:10256"| kp
  sec -.->|"CCM reads once"| ccm
  ccm -.->|"creates LB cert (immutable by name)"| lb
```

Here TLS terminates at the LB, so the certificate is an **OCI LB certificate** the CCM mints from the `swift-oke-tls` secret — which is why replacing it means the rename-and-reannotate dance below.

#### TLS secret

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

#### Deploy and verify

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
| (Option B) Updated the TLS secret but the LB serves the old certificate | OCI LB certificates are immutable by name; the CCM names them after the secret | Create a secret under a **new** name and update the `oci-load-balancer-tls-secret` annotation |
| (Option A) Certificate stays `READY=False` / challenge stuck `Pending` | HTTP-01 can't reach nginx, or a DNS/rate-limit issue | `kubectl get certificate,order,challenge -A` and `kubectl describe` the challenge; confirm `http://<host>/` reaches nginx through the LB (backend health OK, `lb-security-rules.sh` applied); on shared **sslip.io** hosts you can hit Let's Encrypt rate limits — use the staging issuer while testing |
| `kubectl port-forward` / `kubectl exec` return `501 not implemented` | Not supported on virtual nodes | Test via the LB, or run a one-shot curl `Pod`/`Job` hitting the ClusterIP `http://swift-oke.default.svc.cluster.local` and read `kubectl logs` (`logs` works on virtual nodes; `port-forward`/`exec` do not) |

### References

- [Comparing Virtual Nodes with Managed Nodes](https://docs.oracle.com/en-us/iaas/Content/ContEng/Tasks/contengcomparingvirtualwithmanagednodes_topic.htm) — pods as backends, per-pod kube-proxy
- [Network resource configuration for virtual nodes](https://docs.oracle.com/en-us/iaas/Content/ContEng/Tasks/contengnetworkconfig-virtualnodes.htm) — the exact security rules
- [Specifying load balancer / network load balancer annotations](https://docs.oracle.com/en-us/iaas/Content/ContEng/Tasks/contengconfiguringloadbalancersnetworkloadbalancers-subtopic.htm) — pods-as-backends annotations
- [Getting started: best practices for OKE virtual nodes](https://blogs.oracle.com/cloud-infrastructure/getting-started-best-practices-oke-virtual-nodes)
- [cert-manager](https://cert-manager.io/docs/) — ACME issuers and HTTP-01 (Option A)
- [ingress-nginx](https://kubernetes.github.io/ingress-nginx/) — the controller and its cloud provider manifest (Option A)
- [Let's Encrypt — HTTP-01 challenge](https://letsencrypt.org/docs/challenge-types/#http-01-challenge)
- [sslip.io](https://sslip.io) — wildcard DNS that maps any `<name>.<ip>.sslip.io` to that IP

## Notes

- ⚠️ **SDK dependency:** the checked-in `Package.swift` uses a local `path:` reference for developing against an unmerged SDK branch. Switch it to the remote `branch: "main"` (or a tagged release) before `docker build` — the sibling SDK checkout is not in the image build context.
- The workload-identity transport lives in the **opt-in** `OCIKitWorkloadIdentity` product. Consumers who don't use OKE never pull the swift-nio dependency graph.
- Region is read from `OCI_REGION`, falling back to the resource-principal region (`OCI_RESOURCE_PRINCIPAL_REGION`) if the deployment sets it; the namespace is auto-detected via `getNamespace()`.
