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

