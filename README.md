# oci-swift-sdk-examples

A collection of example projects demonstrating how to use the [oci-swift-sdk](https://github.com/iliasaz/oci-swift-sdk) to interact with Oracle Cloud Infrastructure services in Swift-based applications.

---

## 📦 Included Examples

### FileLift

**FileLift** is a lightweight macOS client for uploading files to [Oracle Cloud Infrastructure (OCI)](https://www.oracle.com/europe/cloud/) Object Storage. Designed with simplicity and elegance in mind, it provides a drag-and-drop interface for seamless file transfers.

Key features:
- Retrieves Object Storage namespace
- Lists buckets in a specified compartment
- Uploads files to selected buckets

[View FileLift →](https://github.com/kicsipixel/oci-swift-sdk-examples/tree/main/FileLift)

### BucketView

**BucketView** is a lightweight macOS client for browsing bucket and objets in Oracle Cloud Infrastructure (OCI) Object Storage. Designed with clarity and elegance in mind, it provides a file inspector to view your cloud-stored content.

Key features:
- Retrieves Object Storage namespace
- Lists buckets in a specified compartment
- List objects in the selected bucket

[View BucketView →](https://github.com/kicsipixel/oci-swift-sdk-examples/tree/main/BucketView)

### BucketRelay

**BucketRelay** is a server-side example: a small [Hummingbird](https://github.com/hummingbird-project/hummingbird) REST service that uploads and downloads files to OCI Object Storage. It runs as an **OCI Container Instance** and authenticates with **Resource Principals** — no API keys or config file in the image.

Key features:
- Deploys a Swift server as a container with no VM/OS to manage (Container Instances)
- Authenticates from inside the container via `ResourcePrincipalSigner` (keyless)
- Uploads, downloads, lists, and deletes objects through a public REST API
- Includes scripts for the required networking, bucket, dynamic group, and policy

[View BucketRelay →](./BucketRelay)

### swift-oke

**swift-oke** is a server-side example: a small [Hummingbird](https://github.com/hummingbird-project/hummingbird) REST service that reads a file from OCI Object Storage and returns its text. It runs as a pod in an **OKE (Kubernetes) cluster** and authenticates with **OKE Workload Identity** — no API keys or config file, just the pod's Kubernetes service account.

Key features:
- Authenticates from inside an OKE pod via `OKEWorkloadIdentitySigner` (keyless)
- Pins the in-cluster Kubernetes CA **in-process** (opt-in `OCIKitWorkloadIdentity` product) — no `update-ca-certificates`, no cluster CA step
- Reads an object and serves its content over a REST API
- Includes a Dockerfile and a Kubernetes deployment manifest

[View swift-oke →](./swift-oke)

### apm-tracing

**apm-tracing** is a server-side example: a standalone SwiftPM package that exports OpenTelemetry spans to **OCI Application Performance Monitoring (APM)** with [swift-otel](https://github.com/swift-otel/swift-otel)'s OTLP/HTTP exporter. APM ingests OpenTelemetry natively and authenticates with a **data key**, so there is no signer, no IAM policy and no request signing on the tracing path. It comes in two flavours — a long-running workload and an OCI Function — sharing one small `APMTracing` library.

Key features:
- Ships spans to an APM domain over OTLP/HTTP, authenticated with an APM data key (keyless as far as IAM is concerned)
- `apm-trace-probe` — any long-running Swift workload (Compute VM, OKE, Container Instances); endpoint and key come from the environment
- `apm-trace-function` — an OCI Function; reads the platform's injected tracing configuration through `OCIKitFunctions`' `TracingContext` and parents each invocation's span on the injected `X-B3-*` headers
- Includes a Dockerfile for the function image, and documents what a real run against a live domain actually returned

Needs a live **APM domain** and one of its data keys; nothing here runs without one.

[View apm-tracing →](./apm-tracing)

---

## 🚀 Getting Started

Each example is self-contained and includes setup instructions in its README. To run them, make sure you have:
- A valid OCI configuration file (`~/.oci/config`)
- Swift 6.1+ and Xcode 15 or later
- The oci-swift-sdk integrated via Swift Package Manager

---

## 🧪 Contributing

Feel free to submit your own examples or improvements via pull request. Whether it's a CLI tool, iOS or macOS app or server-side Swift integration — all use cases are welcome.

---

## 📄 License

This repository is licensed under the [MIT License](https://opensource.org/licenses/MIT).

