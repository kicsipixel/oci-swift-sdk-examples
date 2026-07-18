// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "swift-oke",
  platforms: [.macOS(.v15)],
  dependencies: [
    .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.25.0"),
    // Tracks the SDK branch that adds the `OCIKitWorkloadIdentity` product until it
    // merges; switch to `branch: "main"` (or a tagged release) afterwards. For local
    // development against a sibling checkout use `.package(path: "../../oci-swift-sdk")`.
    .package(url: "https://github.com/iliasaz/oci-swift-sdk.git", branch: "feature/oke-workload-identity"),
  ],
  targets: [
    // The Hummingbird service that runs inside the OKE pod.
    .executableTarget(
      name: "App",
      dependencies: [
        .product(name: "Hummingbird", package: "hummingbird"),
        .product(name: "OCIKit", package: "oci-swift-sdk"),
        // The opt-in add-on: in-process CA-pinning transport for OKE Workload Identity.
        .product(name: "OCIKitWorkloadIdentity", package: "oci-swift-sdk"),
      ]
    )
  ]
)
