import Foundation
import HTTPTypes
import Hummingbird
import Logging
import Metrics
import NIOCore
import OCIKit
import OCIKitWorkloadIdentity
import ServiceLifecycle

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

// swift-oke — a tiny Hummingbird REST service that reads a file from OCI Object
// Storage using **OKE Workload Identity**, and ships its own logs and metrics
// back to OCI with the very same credentials. Running inside an OKE pod whose
// Kubernetes service account is mapped (via a condition-based IAM policy) to the
// resources it touches, it authenticates with no API key and no config file:
//
//   * `OKEWorkloadIdentitySigner.fromWorkloadIdentity()` (from OCIKitWorkloadIdentity)
//     exchanges the pod's projected service-account token for a resource
//     principal session token (RPST) against the in-cluster proxymux endpoint,
//     pinning the cluster CA **in-process** (AsyncHTTPClient + NIOSSL). No
//     OS-trust-store install and no cluster CA step are required — parity with
//     the OCI Java/Python/Go SDKs.
//   * Requests to Object Storage are then signed with the RPST.
//   * That one signer also backs two OCIKit observability backends:
//     `OCILogHandler` (a swift-log backend over PutLogs → **OCI Logging**) and
//     `OCIMetricsFactory` (a swift-metrics backend over PostMetricData →
//     **OCI Monitoring**). Application code keeps writing plain `Logger` and
//     `Counter`/`Timer` calls; only the bootstrap below knows about OCI.
//
// Both backends are **opt-in and fail-soft**. With their env vars unset — or if
// the OCI side is misconfigured, or the policy has not propagated yet — the
// service still starts, still serves `/health`, and still logs to stdout so
// `kubectl logs` keeps working. Telemetry never takes the service down.
//
// Configuration (all optional, with demo defaults):
//   OCI_BUCKET    bucket name           (default "bucket-relay-bucket")
//   OCI_OBJECT    object to read        (default "swift-oke-test.txt")
//   OCI_REGION    region id             (falls back to OCI_RESOURCE_PRINCIPAL_REGION)
//   OCI_NAMESPACE Object Storage namespace (auto-detected if unset)
//   PORT          listen port           (default 8080)
//   LOG_LEVEL     swift-log level       (default "info")
//
// Telemetry (opt-in — an unset variable means "off", never "broken"):
//   OCI_LOG_ID            OCID of a custom log in OCI Logging. Unset → console only.
//   OCI_METRICS_NAMESPACE metric namespace, e.g. "swift_oke" — lowercase, no
//                         "oci_"/"oracle_" prefix. Unset → metrics stay no-op.
//   OCI_COMPARTMENT_ID    compartment the metric data is posted into; required
//                         together with OCI_METRICS_NAMESPACE.
//
// Routes:
//   GET /health         liveness (no OCI call)
//   GET /               service info
//   GET /file           read OCI_OBJECT from the bucket and return its text
//   GET /files/{name}   read any object from the bucket and return its text
//   GET /telemetry      delivery counters for both backends

// MARK: - Configuration

let environment = ProcessInfo.processInfo.environment
let bucket = environment["OCI_BUCKET"] ?? "bucket-relay-bucket"
let objectName = environment["OCI_OBJECT"] ?? "swift-oke-test.txt"
let port = Int(environment["PORT"] ?? "8080") ?? 8080
let configuredRegion = environment["OCI_REGION"] ?? environment["OCI_RESOURCE_PRINCIPAL_REGION"]
let configuredNamespace = environment["OCI_NAMESPACE"]
let logLevel = environment["LOG_LEVEL"].flatMap { Logger.Level(rawValue: $0.lowercased()) } ?? .info

/// An env var counts as "set" only if it is also non-empty — a Kubernetes
/// manifest that leaves a placeholder as `value: ""` must not switch a backend on.
func setting(_ name: String) -> String? {
  environment[name].flatMap { $0.isEmpty ? nil : $0 }
}

/// Reports a telemetry backend as `enabled`, `disabled` (deliberately off) or
/// `failed` (configured, but the bootstrap could not build it). Three states
/// worth telling apart when you are staring at an empty log search.
func backendState(live: Bool, configured: Bool) -> String {
  if live { return "enabled" }
  return configured ? "failed" : "disabled"
}

let logId = setting("OCI_LOG_ID")
let metricsNamespace = setting("OCI_METRICS_NAMESPACE")
let compartmentId = setting("OCI_COMPARTMENT_ID")
/// Kubernetes sets HOSTNAME to the pod name — the most useful "who emitted this"
/// label there is, and stable for the pod's lifetime.
let podName = environment["HOSTNAME"] ?? ProcessInfo.processInfo.hostName

// MARK: - Telemetry

/// Everything the process has to drain before it exits. Both halves are
/// optional; the service runs perfectly well with neither.
struct OCITelemetry: Sendable {
  let batcher: OCILogBatcher?
  let metrics: OCIMetricsFactory?

  /// Drains both buffers. Idempotent and non-throwing — a failing flush must not
  /// be able to fail a shutdown.
  ///
  /// Metrics first, so the final `PostMetricData` still has a live logging system
  /// to complain to if the service rejects it.
  func shutdown() async {
    await metrics?.shutdown()
    await batcher?.shutdown()
  }

  /// Delivery counters for both backends, as log metadata.
  ///
  /// These counters are the *only* way to learn that log delivery is broken. The
  /// log backend deliberately never reports its own failures through swift-log —
  /// that would recurse — so a wrong `OCI_LOG_ID` behaves exactly like a healthy
  /// one until you read `log.flushFailures` / `log.lastFlushError` here.
  func statistics() async -> Logger.Metadata {
    var metadata: Logger.Metadata = [:]
    if let batcher {
      let stats = batcher.statistics
      metadata["log.enqueued"] = .stringConvertible(stats.enqueued)
      metadata["log.submitted"] = .stringConvertible(stats.submitted)
      metadata["log.dropped"] = .stringConvertible(stats.dropped)
      metadata["log.failed"] = .stringConvertible(stats.failed)
      metadata["log.flushFailures"] = .stringConvertible(stats.flushFailures)
      metadata["log.lastFlushError"] = .string(stats.lastFlushErrorDescription ?? "none")
    }
    if let metrics {
      let stats = await metrics.statistics()
      metadata["metrics.postedStreams"] = .stringConvertible(stats.postedStreams)
      metadata["metrics.postedDatapoints"] = .stringConvertible(stats.postedDatapoints)
      metadata["metrics.failedMetrics"] = .stringConvertible(stats.failedMetrics)
      metadata["metrics.failedRequests"] = .stringConvertible(stats.failedRequests)
      metadata["metrics.droppedStaleDatapoints"] = .stringConvertible(stats.droppedStaleDatapoints)
      metadata["metrics.droppedBufferedStreams"] = .stringConvertible(stats.droppedBufferedStreams)
      metadata["metrics.droppedSamples"] = .stringConvertible(stats.droppedSamples)
    }
    return metadata
  }
}

// --- Step 1: the signer and the log batcher -------------------------------
//
// This has to happen before `LoggingSystem.bootstrap`, because the bootstrap
// closure captures the batcher. `OCILogBatcher.init` starts its drain and ticker
// tasks immediately, so the batcher is live from construction, not from
// bootstrap. Building the signer performs the first proxymux token exchange and
// is `async` — which is why the whole bootstrap lives in `main.swift`'s async
// top level rather than in a helper.
//
// Chicken-and-egg, worth knowing: the signer builds its own `Logger` while the
// logging system is still un-bootstrapped, so *its* startup lines only reach
// stdout. Everything after `LoggingSystem.bootstrap` reaches OCI too.

var telemetrySigner: OKEWorkloadIdentitySigner?
var telemetryRegion: Region?
var logBatcher: OCILogBatcher?
/// Stashed rather than logged: there is no logging system yet.
var telemetryBootstrapError: (any Error)?

if logId != nil || (metricsNamespace != nil && compartmentId != nil) {
  do {
    // One RPST, three uses: Object Storage, PutLogs and PostMetricData.
    let signer = try await OKEWorkloadIdentitySigner.fromWorkloadIdentity()
    let regionId = configuredRegion ?? signer.region ?? ""
    guard let region = Region.from(regionId: regionId) else {
      throw OCIStore.StoreError.unknownRegion(regionId)
    }
    telemetrySigner = signer
    telemetryRegion = region

    if let logId {
      // Nothing validates `logId` — not the configuration, not the batcher, not
      // the client. A bogus OCID constructs happily and then fails *silently* at
      // flush time. So the "no OCI_LOG_ID → console only" decision is entirely
      // ours to make, right here, by not constructing the batcher at all.
      logBatcher = try OCILogBatcher(
        configuration: OCILogHandlerConfiguration(
          logId: logId,
          // `source` and `subject` are the two fields you can search on in the
          // Logging console; pod name + app name is the pairing that pays off.
          source: podName,
          type: "com.oracle.oci-swift-sdk.swift-oke",
          subject: "swift-oke",
          // Ship at most 5s behind real time, and bound the final flush at
          // shutdown: 3 attempts × 5s timeout + 10s of backoff ≈ 25s worst case,
          // comfortably inside Kubernetes' default 30s termination grace period.
          flushInterval: 5,
          requestTimeout: 5
        ),
        region: region,
        signer: signer
      )
    }
  }
  catch {
    // Fail soft. Remember the error and report it a few lines below, once there
    // is somewhere to report it to.
    telemetryBootstrapError = error
    telemetrySigner = nil
    telemetryRegion = nil
    logBatcher = nil
  }
}

// --- Step 2: bootstrap swift-log ------------------------------------------
//
// Exactly once per process (swift-log traps on a second call) and before
// Hummingbird builds its own `Logger`, or the app logger keeps the pre-bootstrap
// console handler and nothing it writes ever reaches OCI.
//
// The console handler stays in the multiplex on purpose: `kubectl logs` is how
// you debug the pod when the OCI half is the thing that's broken.

let bootstrapBatcher = logBatcher
LoggingSystem.bootstrap { label in
  var console = StreamLogHandler.standardOutput(label: label)
  console.logLevel = logLevel
  guard let bootstrapBatcher else { return console }
  return MultiplexLogHandler([
    console,
    OCILogHandler(label: label, batcher: bootstrapBatcher, logLevel: logLevel),
  ])
}

let log = Logger(label: "swift-oke")

if let telemetryBootstrapError {
  log.warning(
    "telemetry bootstrap failed — continuing with console logging only",
    metadata: ["error": .string("\(telemetryBootstrapError)")]
  )
}

// --- Step 3: bootstrap swift-metrics --------------------------------------
//
// Deliberately *after* the logging bootstrap, so the logger handed to the
// factory writes through the finished logging system. That matters: unlike the
// log backend, the metrics exporter has no recursion guard, so its warnings
// ("the service rejected metric X") are shipped to OCI Logging like any other
// line. It gets its own label so you can filter it out again.

var metricsFactory: OCIMetricsFactory?
if let metricsNamespace, let compartmentId, let signer = telemetrySigner, let region = telemetryRegion {
  do {
    // Note the asymmetry with logging: the Monitoring client is ours to build
    // and hand over, while `OCILogBatcher` builds its ingestion client itself.
    let monitoring = try MonitoringClient(region: region, signer: signer)
    metricsFactory = OCIMetricsFactory(
      client: monitoring,
      configuration: try OCIMetricsConfiguration(
        // The namespace is validated eagerly, here: `[a-z][a-z0-9_]*[a-z0-9]`,
        // no "oci_"/"oracle_" prefix. `swift_oke` is legal, `swift-oke` is not.
        namespace: metricsNamespace,
        compartmentId: compartmentId,
        // Stamped onto every stream, and they win over an instrument's own
        // dimensions on a key collision — operator-set labels app code can't
        // shadow. Both are bounded: one value per deployment, one per pod.
        commonDimensions: ["app": "swift-oke", "pod": podName],
        step: .seconds(60)
      ),
      logger: Logger(label: "swift-oke.metrics")
    )
  }
  catch {
    // Same fail-soft rule: a rejected namespace must not stop the service.
    log.warning(
      "OCI metrics bootstrap failed — metrics stay no-op",
      metadata: ["error": .string("\(error)")]
    )
    metricsFactory = nil
  }
}

if let metricsFactory {
  // Start the step loop first, then publish the factory: instruments created
  // before `start()` still register, and `start()` is idempotent.
  await metricsFactory.start()
  MetricsSystem.bootstrap(metricsFactory)
}

let telemetry = OCITelemetry(batcher: logBatcher, metrics: metricsFactory)

log.info(
  "swift-oke starting",
  metadata: [
    "region": .string(configuredRegion ?? telemetryRegion?.rawValue ?? "unset"),
    "bucket": .string(bucket),
    "object": .string(objectName),
    "port": .stringConvertible(port),
    "ociLogging": .string(backendState(live: logBatcher != nil, configured: logId != nil)),
    "ociMetrics": .string(
      backendState(
        live: metricsFactory != nil,
        configured: metricsNamespace != nil && compartmentId != nil
      )
    ),
  ]
)

// MARK: - OCI store (OKE Workload Identity backed, built once)

/// Lazily builds the workload-identity signer + Object Storage client and
/// resolves the namespace on first use, caching all three. `/health` works even
/// before any OCI call is made.
actor OCIStore {
  private let configuredRegion: String?
  private let configuredNamespace: String?
  private let logger = Logger(label: "swift-oke.store")
  private var cachedSigner: OKEWorkloadIdentitySigner?
  private var cachedClient: ObjectStorageClient?
  private var cachedNamespace: String?

  /// - Parameter signer: A signer built during the telemetry bootstrap, if there
  ///   was one. Reusing it means one RPST — and one proxymux exchange — serves
  ///   Object Storage, Logging and Monitoring alike.
  init(
    configuredRegion: String?,
    configuredNamespace: String?,
    signer: OKEWorkloadIdentitySigner? = nil
  ) {
    self.configuredRegion = configuredRegion
    self.configuredNamespace = configuredNamespace
    self.cachedSigner = signer
  }

  /// The OKE Workload Identity signer, built once. Its construction performs the
  /// first proxymux token exchange (cluster CA pinned in-process).
  func signer() async throws -> OKEWorkloadIdentitySigner {
    if let cachedSigner { return cachedSigner }
    let created = try await OKEWorkloadIdentitySigner.fromWorkloadIdentity()
    logger.info(
      "workload identity: obtained initial RPST",
      metadata: ["region": .string(created.region ?? "unset")]
    )
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
    logger.info("resolved Object Storage namespace", metadata: ["namespace": .string(resolved)])
    cachedNamespace = resolved
    return resolved
  }

  /// Reads an object's bytes, refreshing the workload-identity token first if it
  /// is past its half-life (so a long-running server never signs with a stale RPST).
  func read(_ name: String, from bucket: String) async throws -> Data {
    let signer = try await signer()

    // `refreshIfNeeded()` is a lock read on the fast path and a full proxymux
    // exchange past the RPST's half-life; it returns `Void` either way, so timing
    // it is the only way to tell the two apart from outside the SDK. The rare
    // slow call is exactly the event worth a line in a long-running server: it is
    // the moment the pod's identity is renewed.
    let refreshStart = ContinuousClock.now
    try await signer.refreshIfNeeded()
    let refreshElapsed = ContinuousClock.now - refreshStart
    if refreshElapsed > .milliseconds(20) {
      logger.info(
        "workload identity: RPST refreshed",
        metadata: ["elapsedMs": .stringConvertible(refreshElapsed.wholeMilliseconds)]
      )
    }

    let ns = try await namespace()
    let start = ContinuousClock.now
    do {
      let data = try await client().getObject(
        namespaceName: ns,
        bucketName: bucket,
        objectName: name
      )
      logger.info(
        "object read",
        metadata: [
          "namespace": .string(ns),
          "bucket": .string(bucket),
          "object": .string(name),
          "bytes": .stringConvertible(data.count),
          "elapsedMs": .stringConvertible((ContinuousClock.now - start).wholeMilliseconds),
        ]
      )
      return data
    }
    catch {
      logger.error(
        "object read failed",
        metadata: [
          "namespace": .string(ns),
          "bucket": .string(bucket),
          "object": .string(name),
          "error": .string("\(error)"),
          "elapsedMs": .stringConvertible((ContinuousClock.now - start).wholeMilliseconds),
        ]
      )
      throw error
    }
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

let store = OCIStore(
  configuredRegion: configuredRegion,
  configuredNamespace: configuredNamespace,
  signer: telemetrySigner
)

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

extension Swift.Duration {
  /// Whole milliseconds — plenty of resolution for a log line, and an `Int64`
  /// renders far more kindly in log metadata than a `Duration` does.
  ///
  /// Spelled `Swift.Duration` throughout: `import OCIKit` brings an Object
  /// Storage lifecycle model also named `Duration` into scope, and it shadows the
  /// standard library type.
  var wholeMilliseconds: Int64 {
    components.seconds * 1_000 + components.attoseconds / 1_000_000_000_000_000
  }
}

// MARK: - Metrics middleware

/// Records one counter and one timer per request.
///
/// The dimension set is deliberately **bounded**: the route *template*
/// (`/files/:name` — never the expanded path), the HTTP method, and the status
/// *class* rather than the exact code. Every distinct combination of dimension
/// values mints its own metric stream in OCI Monitoring, so a dimension carrying
/// user input — an object name, a request id, a raw URI — mints an unbounded
/// number of them: expensive, unqueryable, and the single easiest way to make a
/// metrics bill interesting. `app` and `pod` are added to every stream for free
/// by the factory's `commonDimensions`.
///
/// Hummingbird ships its own `MetricsMiddleware` with a richer (and
/// higher-cardinality) dimension set and a cache of pre-built instruments; this
/// one is written out longhand because the cardinality choice is the lesson.
struct RequestMetricsMiddleware<Context: RequestContext>: RouterMiddleware {
  func handle(
    _ request: Request,
    context: Context,
    next: (Request, Context) async throws -> Response
  ) async throws -> Response {
    let start = ContinuousClock.now
    do {
      let response = try await next(request, context)
      record(request, context, status: response.status.code, since: start)
      return response
    }
    catch {
      // A thrown error is still a request that happened — record it as the status
      // the client will actually be handed, then rethrow untouched.
      let status = (error as? any HTTPResponseError)?.status.code ?? 500
      record(request, context, status: status, since: start)
      throw error
    }
  }

  private func record(
    _ request: Request,
    _ context: Context,
    status: Int,
    since start: ContinuousClock.Instant
  ) {
    let dimensions = [
      ("route", context.endpointPath ?? "unmatched"),
      ("method", request.method.rawValue),
      ("status_class", "\(status / 100)xx"),
    ]
    // A counter is exported as the per-step *delta*, so an idle step posts
    // nothing at all rather than a flat line of zeroes.
    Counter(label: "http_requests_total", dimensions: dimensions).increment()
    // `Metrics.Timer` module-qualified: a bare `Timer` resolves to
    // `Foundation.Timer`. The OCI backend records timers in nanoseconds and tags
    // the datapoints `unit=ns`.
    Metrics.Timer(label: "http_request_duration", dimensions: dimensions)
      .record(duration: ContinuousClock.now - start)
  }
}

// MARK: - Routes

let router = Router()

// Order matters: logging first so every request is accounted for even if the
// metrics middleware is the thing that throws.
router.middlewares.add(LogRequestsMiddleware(.info))
router.middlewares.add(RequestMetricsMiddleware())

router.get("/health") { _, _ in "ok\n" }

router.get("/") { _, _ in
  """
  swift-oke — OCIKit + Hummingbird, authenticated with OCI OKE Workload Identity.
  bucket=\(bucket) object=\(objectName)

    GET /file            read \(objectName) from \(bucket) and return its text
    GET /files/{name}    read any object from \(bucket)
    GET /telemetry       OCI logging/metrics delivery counters

  """
}

// The star of the demo: read the configured object and return its text.
//
// `OCIStore` already logs the outcome of the Object Storage call itself; the
// catch here logs the *request* outcome through `context.logger`, which carries
// Hummingbird's `hb.request.id` — so a failure that never reached Object Storage
// (a token exchange that failed, an unresolvable namespace) is still visible,
// and every line for one request can be correlated in the Logging console.
router.get("/file") { _, context -> Response in
  do {
    let data = try await store.read(objectName, from: bucket)
    return text(.ok, renderText(data))
  }
  catch {
    context.logger.error(
      "request failed",
      metadata: ["object": .string(objectName), "error": .string("\(error)")]
    )
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
    context.logger.error(
      "request failed",
      metadata: ["object": .string(name), "error": .string("\(error)")]
    )
    return text(.notFound, "reading \(name) failed: \(error)\n")
  }
}

// Telemetry self-report. Both backends absorb every delivery failure into
// counters instead of throwing, so this endpoint is how you find out that a
// missing `use log-content` policy is quietly eating your log entries — handy on
// virtual nodes, where `kubectl exec` is not available.
router.get("/telemetry") { _, _ -> Response in
  let metricsConfigured = metricsNamespace != nil && compartmentId != nil
  var lines = [
    "logging: "
      + backendState(live: telemetry.batcher != nil, configured: logId != nil)
      + (logId == nil ? " (OCI_LOG_ID unset)" : ""),
    "metrics: "
      + backendState(live: telemetry.metrics != nil, configured: metricsConfigured)
      + (telemetry.metrics != nil
        ? " (namespace=\(metricsNamespace ?? "?"))"
        : metricsConfigured ? "" : " (OCI_METRICS_NAMESPACE/OCI_COMPARTMENT_ID unset)"),
  ]
  for (key, value) in await telemetry.statistics().sorted(by: { $0.key < $1.key }) {
    lines.append("\(key) = \(value)")
  }
  return text(.ok, lines.joined(separator: "\n") + "\n")
}

// MARK: - Shutdown

/// A `ServiceLifecycle` service whose entire job is to drain the telemetry
/// buffers when the pod is terminating.
///
/// This is why it is a `Service` rather than a signal handler: Hummingbird runs
/// its own `ServiceGroup`, composed as `addServices(…) + [dateCache, server]`,
/// and a `ServiceGroup` shuts services down in **reverse** order, waiting for
/// each one before triggering the next. A service added here is therefore torn
/// down *after* the HTTP server has stopped — the last request has been logged
/// and counted, and nothing more will arrive.
///
/// `ServiceLifecycle.Service` is spelled in full because `import OCIKit` brings
/// an unrelated `Service` enum (the OCI service catalogue) into scope.
struct TelemetryFlushService: ServiceLifecycle.Service {
  let telemetry: OCITelemetry
  let logger: Logger

  func run() async throws {
    // Nothing to do while the server runs: park here until the group begins a
    // graceful shutdown (the kubelet's SIGTERM, which `runService` traps).
    try await gracefulShutdown()

    logger.info("draining telemetry buffers")
    await telemetry.shutdown()

    // After `shutdown()` the OCI log handler discards records, so this last line
    // only reaches stdout — which is exactly where you want it, since it is the
    // line that tells you whether the *final* flush landed. (`metadata:` is an
    // autoclosure, so the counters have to be read before the call, not inside it.)
    let counters = await telemetry.statistics()
    logger.info("telemetry drained", metadata: counters)
  }
}

// MARK: - Run

var app = Application(
  router: router,
  configuration: .init(address: .hostname("0.0.0.0", port: port), serverName: "swift-oke")
)
app.logger.logLevel = logLevel
app.addServices(TelemetryFlushService(telemetry: telemetry, logger: log))
try await app.runService()
