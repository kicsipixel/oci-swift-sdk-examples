import Foundation
import HTTPTypes
import Hummingbird
import NIOCore
import OCIKit

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

// BucketRelay — a tiny Hummingbird REST service that relays files to and from an
// OCI Object Storage bucket. It authenticates to OCI with **Resource Principals
// v2.2** (no API keys, no config file): when this container runs as an OCI
// Container Instance, OCI injects the `OCI_RESOURCE_PRINCIPAL_*` environment
// that OCIKit's `ResourcePrincipalSigner` reads automatically.
//
// The image is self-configuring — the only thing it needs baked in is the bucket
// name (hardcoded default below):
//   * region    comes from the resource principal (OCI_RESOURCE_PRINCIPAL_REGION)
//   * namespace is auto-detected at runtime via Object Storage getNamespace()
//   * bucket    defaults to "bucket-relay-bucket" (override with OCI_BUCKET)
//
// Routes:
//   GET    /health          liveness (does not call OCI)
//   GET    /                service info
//   GET    /files           list objects in the bucket           (JSON)
//   GET    /files/{name}     download an object
//   PUT    /files/{name}     upload the request body as an object
//   DELETE /files/{name}     delete an object

// MARK: - Configuration

let environment = ProcessInfo.processInfo.environment

// The bucket is the one thing the image needs to know. Hardcoded default for the
// ready-to-use image; override with OCI_BUCKET if your bucket has a different name.
let bucket = environment["OCI_BUCKET"] ?? "bucket-relay-bucket"
let port = Int(environment["PORT"] ?? "8080") ?? 8080

// Region comes from the resource principal OCI injects (fallback: OCI_REGION).
let regionId = environment["OCI_REGION"] ?? environment["OCI_RESOURCE_PRINCIPAL_REGION"] ?? ""
guard let region = Region.from(regionId: regionId) else {
  FileHandle.standardError.write(Data("BucketRelay: unknown/empty region '\(regionId)'. Set OCI_REGION.\n".utf8))
  exit(2)
}

// Namespace is auto-detected at runtime (see OCIStore); override with OCI_NAMESPACE.
let configuredNamespace = environment["OCI_NAMESPACE"]

// MARK: - OCI client (Resource Principal backed, built once)

/// Lazily builds the RP-backed Object Storage client and resolves the Object
/// Storage namespace on first use, caching both. `/health` therefore works even
/// before any OCI call is made.
actor OCIStore {
  private let region: Region
  private let configuredNamespace: String?
  private var cachedClient: ObjectStorageClient?
  private var cachedNamespace: String?

  init(region: Region, configuredNamespace: String?) {
    self.region = region
    self.configuredNamespace = configuredNamespace
  }

  func client() throws -> ObjectStorageClient {
    if let cachedClient { return cachedClient }
    // ResourcePrincipalSigner.fromEnvironment() reads the OCI_RESOURCE_PRINCIPAL_*
    // env vars OCI injects into the container instance.
    let signer = try ResourcePrincipalSigner.fromEnvironment()
    let created = try ObjectStorageClient(region: region, signer: signer)
    cachedClient = created
    return created
  }

  /// The Object Storage namespace — from OCI_NAMESPACE if set, otherwise fetched
  /// once via `getNamespace()` (authenticated with the resource principal).
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
}
let store = OCIStore(region: region, configuredNamespace: configuredNamespace)

// MARK: - Helpers

@Sendable func text(_ status: HTTPResponse.Status, _ message: String) -> Response {
  var headers = HTTPFields()
  headers[.contentType] = "text/plain; charset=utf-8"
  return Response(status: status, headers: headers, body: .init(byteBuffer: ByteBuffer(string: message)))
}

@Sendable func json(_ status: HTTPResponse.Status, _ data: Data) -> Response {
  var headers = HTTPFields()
  headers[.contentType] = "application/json"
  return Response(status: status, headers: headers, body: .init(byteBuffer: ByteBuffer(bytes: data)))
}

struct FileEntry: Encodable { let name: String; let size: Int? }

// MARK: - Routes

let router = Router()

router.get("/health") { _, _ in "ok\n" }

router.get("/") { _, _ in
  """
  BucketRelay — OCIKit + Hummingbird, authenticated with OCI Resource Principals.
  bucket=\(bucket) region=\(region.rawValue) (namespace auto-detected)

    GET    /files          list objects
    GET    /files/{name}   download
    PUT    /files/{name}   upload (body = file contents)
    DELETE /files/{name}   delete

  """
}

// List objects in the bucket.
router.get("/files") { _, _ -> Response in
  do {
    let ns = try await store.namespace()
    let listing = try await store.client().listObjects(
      namespaceName: ns, bucketName: bucket, fields: [.name, .size])
    let entries = listing.objects.map { FileEntry(name: $0.name, size: $0.size) }
    return json(.ok, try JSONEncoder().encode(entries))
  }
  catch {
    return text(.internalServerError, "list failed: \(error)\n")
  }
}

// Download an object.
router.get("/files/:name") { _, context -> Response in
  let name = try context.parameters.require("name")
  do {
    let ns = try await store.namespace()
    let data = try await store.client().getObject(namespaceName: ns, bucketName: bucket, objectName: name)
    return json(.ok, data)  // returned as-is; text/JSON payloads render fine for the demo
  }
  catch {
    return text(.notFound, "GET \(name) failed: \(error)\n")
  }
}

// Upload the request body as an object.
router.put("/files/:name") { request, context -> Response in
  let name = try context.parameters.require("name")
  let buffer = try await request.body.collect(upTo: 16 * 1024 * 1024)  // 16 MB cap
  let data = Data(buffer.readableBytesView)
  do {
    let ns = try await store.namespace()
    try await store.client().putObject(namespaceName: ns, bucketName: bucket, objectName: name, putObjectBody: data)
    return text(.created, "stored \(name) (\(data.count) bytes)\n")
  }
  catch {
    return text(.internalServerError, "PUT \(name) failed: \(error)\n")
  }
}

// Delete an object.
router.delete("/files/:name") { _, context -> Response in
  let name = try context.parameters.require("name")
  do {
    let ns = try await store.namespace()
    try await store.client().deleteObject(namespaceName: ns, bucketName: bucket, objectName: name)
    return text(.ok, "deleted \(name)\n")
  }
  catch {
    return text(.internalServerError, "DELETE \(name) failed: \(error)\n")
  }
}

// MARK: - Run

var app = Application(
  router: router,
  configuration: .init(address: .hostname("0.0.0.0", port: port), serverName: "bucket-relay")
)
app.logger.logLevel = .info
try await app.runService()
