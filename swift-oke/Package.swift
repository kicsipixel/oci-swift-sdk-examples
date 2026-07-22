// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "swift-oke",
  platforms: [.macOS(.v15)],
  dependencies: [
    .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.25.0"),
    // Tracks the SDK branch that adds the `OCIKitWorkloadIdentity` product and the
    // OCI swift-log / swift-metrics backends until it merges; switch to
    // `branch: "main"` (or a tagged release) afterwards. For local development
    // against a sibling checkout use `.package(path: "../../oci-swift-sdk")`.
    .package(url: "https://github.com/iliasaz/oci-swift-sdk.git", branch: "feature/observability-85"),
    // All three are already in the graph via Hummingbird and OCIKit. They are
    // declared explicitly because this target imports them by name: swift-log to
    // bootstrap the logging system, swift-metrics to record instruments, and
    // swift-service-lifecycle to hang the telemetry flush off the shutdown path.
    .package(url: "https://github.com/apple/swift-log.git", from: "1.14.0"),
    .package(url: "https://github.com/apple/swift-metrics.git", from: "2.11.0"),
    .package(url: "https://github.com/swift-server/swift-service-lifecycle.git", from: "2.0.0"),
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
        .product(name: "Logging", package: "swift-log"),
        .product(name: "Metrics", package: "swift-metrics"),
        .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
      ]
    )
  ]
)
