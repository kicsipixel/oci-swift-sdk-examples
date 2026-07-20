import ArgumentParser
import Foundation
import OCIKit

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

// `brctl` — a small CLI that manages the BucketRelay Container Instance using
// OCIKit's `ContainerInstancesClient` (instead of the `oci` CLI). It shows how
// to create, inspect, fetch logs from, and delete a Container Instance in Swift.
//
// Auth: uses your ~/.oci/config. API-key auth by default; set
// OCI_CLI_AUTH=security_token to use a session-token profile instead.

// MARK: - Shared helpers

func envVar(_ key: String, _ fallback: String = "") -> String {
  ProcessInfo.processInfo.environment[key] ?? fallback
}

struct GlobalOptions: ParsableArguments {
  @Option(name: .shortAndLong, help: "OCI config profile.")
  var profile: String = envVar("OCI_CLI_PROFILE", "DEFAULT")

  @Option(name: .shortAndLong, help: "Region id, e.g. us-phoenix-1.")
  var region: String = envVar("REGION")
}

func makeClient(_ global: GlobalOptions) throws -> ContainerInstancesClient {
  guard let region = Region.from(regionId: global.region) else {
    throw ValidationError("Unknown or empty region '\(global.region)'. Pass --region or set REGION.")
  }
  let configPath = "\(NSHomeDirectory())/.oci/config"
  let signer: Signer =
    envVar("OCI_CLI_AUTH") == "security_token"
    ? try SecurityTokenSigner(configFilePath: configPath, configName: global.profile)
    : try APIKeySigner(configFilePath: configPath, configName: global.profile)
  return try ContainerInstancesClient(region: region, signer: signer)
}

// MARK: - brctl

@main
struct BucketRelayCtl: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "brctl",
    abstract: "Manage the BucketRelay Container Instance with OCIKit.",
    subcommands: [Create.self, List.self, Get.self, Status.self, Logs.self, Delete.self]
  )
}

// MARK: - create

struct Create: AsyncParsableCommand {
  static let configuration = CommandConfiguration(abstract: "Create the container instance and wait until it is ACTIVE.")

  @OptionGroup var global: GlobalOptions
  @Option(help: "Compartment OCID.") var compartment = envVar("COMPARTMENT_ID")
  @Option(help: "Subnet OCID (from provisioning).") var subnet = envVar("SUBNET_ID")
  @Option(name: .customLong("availability-domain"), help: "Availability domain name.") var ad = envVar("AVAILABILITY_DOMAIN")
  @Option(help: "Container image URL.") var image = envVar("IMAGE")
  @Option(help: "Container Instance shape.") var shape = envVar("SHAPE", "CI.Standard.A1.Flex")
  @Option(help: "OCPUs.") var ocpus = Float(envVar("OCPUS", "1")) ?? 1
  @Option(name: .customLong("memory-gbs"), help: "Memory in GB.") var memory = Float(envVar("MEMORY_GBS", "6")) ?? 6
  @Option(help: "Bucket name (injected as OCI_BUCKET).") var bucket = envVar("OCI_BUCKET", "bucket-relay-bucket")
  @Option(name: .customLong("display-name")) var displayName = "bucket-relay"

  func run() async throws {
    for (name, value) in [("--compartment", compartment), ("--subnet", subnet), ("--availability-domain", ad), ("--image", image)] {
      if value.isEmpty { throw ValidationError("Missing \(name) (or its env var).") }
    }
    let client = try makeClient(global)

    let details = CreateContainerInstanceDetails(
      displayName: displayName,
      compartmentId: compartment,
      availabilityDomain: ad,
      shape: shape,
      shapeConfig: CreateContainerInstanceShapeConfigDetails(ocpus: ocpus, memoryInGBs: memory),
      containers: [
        CreateContainerDetails(
          displayName: "bucket-relay",
          imageUrl: image,
          // The image only needs the bucket; it auto-detects region (from the
          // resource principal) and namespace (via getNamespace) at runtime.
          environmentVariables: ["OCI_BUCKET": bucket]
        )
      ],
      vnics: [CreateContainerVnicDetails(displayName: "primary", isPublicIpAssigned: true, subnetId: subnet)],
      containerRestartPolicy: .always,
      freeformTags: ["purpose": "bucket-relay-example"]
    )

    var instance = try await client.createContainerInstance(createContainerInstanceDetails: details)
    print("created \(instance.id)  state=\(instance.lifecycleState.rawValue)")

    for _ in 0..<40 where instance.lifecycleState != .active {
      if instance.lifecycleState == .failed {
        throw ValidationError("Instance FAILED: \(instance.lifecycleDetails ?? "")")
      }
      try await Task.sleep(for: .seconds(10))
      instance = try await client.getContainerInstance(containerInstanceId: instance.id)
      print("  state=\(instance.lifecycleState.rawValue)")
    }

    print("\ninstance: \(instance.id)")
    if let vnicId = instance.vnics.first?.vnicId {
      // OCIKit has no VNIC/networking client yet, so fetch the public IP via the oci CLI:
      print("public IP: oci network vnic get --vnic-id \(vnicId) --query 'data.\"public-ip\"' --raw-output")
    }
    print(
      """

      The service listens on port 8080. Once you have the public IP:
        GET    http://<public-ip>:8080/health
        GET    http://<public-ip>:8080/files
        PUT    http://<public-ip>:8080/files/{name}   (body = file contents)
        GET    http://<public-ip>:8080/files/{name}
        DELETE http://<public-ip>:8080/files/{name}

      logs:   swift run brctl logs \(instance.id)
      delete: swift run brctl delete \(instance.id)
      """)
  }
}

// MARK: - status

struct Status: AsyncParsableCommand {
  static let configuration = CommandConfiguration(abstract: "Show the instance's lifecycle state.")
  @OptionGroup var global: GlobalOptions
  @Argument(help: "Container instance OCID.") var instanceId: String

  func run() async throws {
    let instance = try await makeClient(global).getContainerInstance(containerInstanceId: instanceId)
    print("state:      \(instance.lifecycleState.rawValue)")
    print("containers: \(instance.containers.count)")
    if let vnicId = instance.vnics.first?.vnicId { print("vnic:       \(vnicId)") }
  }
}

// MARK: - logs

struct Logs: AsyncParsableCommand {
  static let configuration = CommandConfiguration(abstract: "Fetch the most recent container logs (up to 256 KB).")
  @OptionGroup var global: GlobalOptions
  @Argument(help: "Container instance OCID.") var instanceId: String

  func run() async throws {
    let client = try makeClient(global)
    let instance = try await client.getContainerInstance(containerInstanceId: instanceId)
    guard let containerId = instance.containers.first?.containerId else {
      throw ValidationError("Instance has no containers yet (state=\(instance.lifecycleState.rawValue)).")
    }
    print(try await client.retrieveLogs(containerId: containerId), terminator: "")
  }
}

// MARK: - list

struct List: AsyncParsableCommand {
  static let configuration = CommandConfiguration(abstract: "List the container instances in a compartment.")
  @OptionGroup var global: GlobalOptions
  @Option(help: "Compartment OCID.") var compartment = envVar("COMPARTMENT_ID")
  @Option(name: .customLong("lifecycle-state"), help: "Filter by state, e.g. ACTIVE.") var lifecycleState: String?

  func run() async throws {
    if compartment.isEmpty { throw ValidationError("Missing --compartment (or COMPARTMENT_ID).") }
    let state = lifecycleState.flatMap { ContainerInstanceLifecycleState(rawValue: $0.uppercased()) }
    let collection = try await makeClient(global).listContainerInstances(compartmentId: compartment, lifecycleState: state)
    if collection.items.isEmpty {
      print("(no container instances)")
      return
    }
    for item in collection.items {
      let state = item.lifecycleState.rawValue.padding(toLength: 9, withPad: " ", startingAt: 0)
      print("\(state)  \(item.displayName)  \(item.id)")
    }
  }
}

// MARK: - get

struct Get: AsyncParsableCommand {
  static let configuration = CommandConfiguration(abstract: "Print a container instance as JSON.")
  @OptionGroup var global: GlobalOptions
  @Argument(help: "Container instance OCID.") var instanceId: String

  func run() async throws {
    let instance = try await makeClient(global).getContainerInstance(containerInstanceId: instanceId)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    print(String(data: try encoder.encode(instance), encoding: .utf8) ?? "")
  }
}

// MARK: - delete

struct Delete: AsyncParsableCommand {
  static let configuration = CommandConfiguration(abstract: "Delete the container instance.")
  @OptionGroup var global: GlobalOptions
  @Argument(help: "Container instance OCID.") var instanceId: String

  func run() async throws {
    let workRequest = try await makeClient(global).deleteContainerInstance(containerInstanceId: instanceId)
    print("delete accepted. work request: \(workRequest ?? "-")")
  }
}
