import Foundation
import HTTPTypes
import Hummingbird
import NIOCore
import OCIKit
import OCIKitWorkloadIdentity

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

// swift-oke — a tiny Hummingbird REST service that reads a file from OCI Object
// Storage using **OKE Workload Identity**. Running inside an OKE pod whose
// Kubernetes service account is mapped (via an OCI dynamic group + IAM policy)
// to Object Storage read access, it authenticates with no API key and no config
// file:
//
//   * `OKEWorkloadIdentitySigner.fromWorkloadIdentity()` (from OCIKitWorkloadIdentity)
//     exchanges the pod's projected service-account token for a resource
//     principal session token (RPST) against the in-cluster proxymux endpoint,
//     pinning the cluster CA **in-process** (AsyncHTTPClient + NIOSSL). No
//     OS-trust-store install and no cluster CA step are required — parity with
//     the OCI Java/Python/Go SDKs.
//   * Requests to Object Storage are then signed with the RPST.
//
// Configuration (all optional, with demo defaults):
//   OCI_BUCKET   bucket name           (default "bucket-relay-bucket")
//   OCI_OBJECT   object to read        (default "swift-oke-test.txt")
//   OCI_REGION   region id             (falls back to OCI_RESOURCE_PRINCIPAL_REGION)
//   OCI_NAMESPACE Object Storage namespace (auto-detected if unset)
//   PORT         listen port           (default 8080)
//
// Routes:
//   GET /health         liveness (no OCI call)
//   GET /               service info
//   GET /file           read OCI_OBJECT from the bucket and return its text
//   GET /files/{name}   read any object from the bucket and return its text

// MARK: - Configuration

let environment = ProcessInfo.processInfo.environment
let bucket = environment["OCI_BUCKET"] ?? "bucket-relay-bucket"
let objectName = environment["OCI_OBJECT"] ?? "swift-oke-test.txt"
let port = Int(environment["PORT"] ?? "8080") ?? 8080
let configuredRegion = environment["OCI_REGION"] ?? environment["OCI_RESOURCE_PRINCIPAL_REGION"]
let configuredNamespace = environment["OCI_NAMESPACE"]

// MARK: - OCI store (OKE Workload Identity backed, built once)

/// Lazily builds the workload-identity signer + Object Storage client and
/// resolves the namespace on first use, caching all three. `/health` works even
/// before any OCI call is made.
actor OCIStore {
  private let configuredRegion: String?
  private let configuredNamespace: String?
  private var cachedSigner: OKEWorkloadIdentitySigner?
  private var cachedClient: ObjectStorageClient?
  private var cachedNamespace: String?

  init(configuredRegion: String?, configuredNamespace: String?) {
    self.configuredRegion = configuredRegion
    self.configuredNamespace = configuredNamespace
  }

  /// The OKE Workload Identity signer, built once. Its construction performs the
  /// first proxymux token exchange (cluster CA pinned in-process).
  func signer() async throws -> OKEWorkloadIdentitySigner {
    if let cachedSigner { return cachedSigner }
    let created = try await OKEWorkloadIdentitySigner.fromWorkloadIdentity()
    cachedSigner = created
    return created
  }

  func client() async throws -> ObjectStorageClient {
    if let cachedClient { return cachedClient }
    let signer = try await signer()
    let regionId = configuredRegion ?? signer.region ?? ""
    guard let region = Region.from(regionId: regionId) else {
      throw StoreError.unknownRegion(regionId)
    }
    let created = try ObjectStorageClient(region: region, signer: signer)
    cachedClient = created
    return created
  }

  /// The Object Storage namespace — from OCI_NAMESPACE if set, else fetched once.
  func namespace() async throws -> String {
    if let cachedNamespace { return cachedNamespace }
    if let configuredNamespace, !configuredNamespace.isEmpty {
      cachedNamespace = configuredNamespace
      return configuredNamespace
    }
    let resolved = try await client().getNamespace()
    cachedNamespace = resolved
    return resolved
  }

  /// Reads an object's bytes, refreshing the workload-identity token first if it
  /// is past its half-life (so a long-running server never signs with a stale RPST).
  func read(_ name: String, from bucket: String) async throws -> Data {
    try await signer().refreshIfNeeded()
    let ns = try await namespace()
    return try await client().getObject(namespaceName: ns, bucketName: bucket, objectName: name)
  }

  enum StoreError: Error, CustomStringConvertible {
    case unknownRegion(String)
    var description: String {
      switch self {
      case .unknownRegion(let regionId):
        return
          "unknown/empty region '\(regionId)'. Set OCI_REGION or OCI_RESOURCE_PRINCIPAL_REGION."
      }
    }
  }
}

let store = OCIStore(configuredRegion: configuredRegion, configuredNamespace: configuredNamespace)

// MARK: - Helpers

@Sendable func text(_ status: HTTPResponse.Status, _ message: String) -> Response {
  var headers = HTTPFields()
  headers[.contentType] = "text/plain; charset=utf-8"
  return Response(status: status, headers: headers, body: .init(byteBuffer: ByteBuffer(string: message)))
}

/// Renders object bytes as UTF-8 text, or a placeholder for binary content.
func renderText(_ data: Data) -> String {
  String(data: data, encoding: .utf8) ?? "<\(data.count) bytes of non-UTF8 data>"
}

// MARK: - Routes

let router = Router()

router.get("/health") { _, _ in "ok\n" }

router.get("/") { _, _ in
  """
  swift-oke — OCIKit + Hummingbird, authenticated with OCI OKE Workload Identity.
  bucket=\(bucket) object=\(objectName)

    GET /file            read \(objectName) from \(bucket) and return its text
    GET /files/{name}    read any object from \(bucket)

  """
}

// The star of the demo: read the configured object and return its text.
router.get("/file") { _, _ -> Response in
  do {
    let data = try await store.read(objectName, from: bucket)
    return text(.ok, renderText(data))
  }
  catch {
    return text(.internalServerError, "reading \(objectName) failed: \(error)\n")
  }
}

// Read any object by name.
router.get("/files/:name") { _, context -> Response in
  let name = try context.parameters.require("name")
  do {
    let data = try await store.read(name, from: bucket)
    return text(.ok, renderText(data))
  }
  catch {
    return text(.notFound, "reading \(name) failed: \(error)\n")
  }
}

// MARK: - Run

var app = Application(
  router: router,
  configuration: .init(address: .hostname("0.0.0.0", port: port), serverName: "swift-oke")
)
app.logger.logLevel = .info
try await app.runService()
