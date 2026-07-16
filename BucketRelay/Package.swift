// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "BucketRelay",
  platforms: [.macOS(.v15)],
  dependencies: [
    .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.25.0"),
    .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
    .package(url: "https://github.com/iliasaz/oci-swift-sdk.git", branch: "main"),
  ],
  targets: [
    // The Hummingbird service that runs inside the Container Instance.
    .executableTarget(
      name: "App",
      dependencies: [
        .product(name: "Hummingbird", package: "hummingbird"),
        .product(name: "OCIKit", package: "oci-swift-sdk"),
      ]
    ),
    // `brctl` — a CLI that manages the Container Instance with OCIKit
    // (create / status / logs / delete). Not part of the container image.
    .executableTarget(
      name: "brctl",
      dependencies: [
        .product(name: "OCIKit", package: "oci-swift-sdk"),
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
      ]
    ),
  ]
)
