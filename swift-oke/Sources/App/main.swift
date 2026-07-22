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
/// Who emitted this — stamped on every log entry (`source`) and every metric
/// stream (the `pod` dimension), and stable for the pod's lifetime.
///
/// `POD_NAME` comes from the downward API (`fieldRef: metadata.name`) that
/// `deploy/swift-oke.yaml` injects, and it is the only reliable source here.
/// The usual shortcut — trusting `HOSTNAME` — is a trap on **virtual nodes**:
/// verified on this cluster, the pod's `HOSTNAME` is `localhost`, not
/// `swift-oke-<replicaset>-<suffix>`, so every replica reports the same name and
/// the label you were counting on to tell them apart quietly stops meaning
/// anything. `ProcessInfo.processInfo.hostName` degrades the same way.
let podName =
  environment["POD_NAME"] ?? environment["HOSTNAME"] ?? ProcessInfo.processInfo.hostName

// MARK: - Telemetry

/// Everything the process has to drain before it exits. Both halves are
/// optional; the service runs perfectly well with neither.
struct OCITelemetry: Sendable {
  let batcher: OCILogBatcher?
  let metrics: OCIMetricsFactory?

  /// Drains both buffers. Idempotent and non-throwing — a failing flush must not
  /// be able to fail a shutdown.
  ///
  /// **Logs first, deliberately.** Both halves compete for the one
  /// `terminationGracePeriodSeconds` budget, and the log buffer is the half worth
  /// saving: it holds up to 10,000 records, among them the error lines that
  /// explain whatever is making the pod go away. Draining metrics first would
  /// spend the budget on one step of counters and risk a SIGKILL arriving before
  /// any of those records shipped.
  ///
  /// The price is small and known: once the batcher has shut down the OCI log
  /// handler discards records, so the metrics exporter's own warnings ("the
  /// service rejected metric X") land in `kubectl logs` but not in OCI Logging.
  func shutdown() async {
    await batcher?.shutdown()
    await metrics?.shutdown()
  }

  /// Delivery counters for both backends, as log metadata.
  ///
  /// These counters are the *only* way to learn that log delivery is broken. The
  /// log backend deliberately never reports its own failures through swift-log —
  /// that would recurse — so a wrong `OCI_LOG_ID` behaves exactly like a healthy
  /// one until you read `log.flushFailures` / `log.lastFlushError` here.
  ///
  /// - Parameter redactingErrors: When `true`, `log.lastFlushError` is reduced to
  ///   the failing error's case name. The batcher records `String(describing:)`
  ///   of whatever `PutLogs` threw, and `LoggingIngestionError.unexpectedStatusCode`
  ///   carries the service's *raw response body* — message text and `opc-request-id`
  ///   included. That is the right thing to print into `kubectl logs` and the
  ///   wrong thing to hand to an unauthenticated caller of `GET /telemetry`.
  func statistics(redactingErrors: Bool = false) async -> Logger.Metadata {
    var metadata: Logger.Metadata = [:]
    if let batcher {
      let stats = batcher.statistics
      metadata["log.enqueued"] = .stringConvertible(stats.enqueued)
      metadata["log.submitted"] = .stringConvertible(stats.submitted)
      metadata["log.dropped"] = .stringConvertible(stats.dropped)
      metadata["log.failed"] = .stringConvertible(stats.failed)
      metadata["log.flushFailures"] = .stringConvertible(stats.flushFailures)
      let lastError = stats.lastFlushErrorDescription.map {
        redactingErrors ? Self.errorSummary(of: $0) : $0
      }
      metadata["log.lastFlushError"] = .string(lastError ?? "none")
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

  /// The leading case name of a `String(describing:)`-rendered error — e.g.
  /// `unexpectedStatusCode` — which distinguishes "wrong OCID" from "no route to
  /// the endpoint" without echoing the service's payload back to the caller.
  static func errorSummary(of description: String) -> String {
    let head = description.prefix { $0 != "(" && $0 != ":" }
    return head.isEmpty ? "error" : String(head)
  }
}

// --- Step 0: a deadline for the bootstrap ---------------------------------
//
// The proxymux token exchange below is the only thing standing between process
// start and the listener's `bind()`, and nothing bounds it usefully:
// `OKEProxymuxTransport.caPinned` allows 30s and makes one attempt. An
// unreachable proxymux (a missing egress rule, a control-plane blip, a cluster
// CA that has not been projected yet) would therefore hold the bind for 30s
// while the kubelet probed a socket that does not exist yet — and the fail-soft
// `catch` below would never be reached. CrashLoopBackOff is a much worse
// outcome than "no telemetry".
//
// Ten seconds keeps the bind off that critical path while still allowing for a
// cold CNI path on a virtual node. `deploy/swift-oke.yaml` belts-and-braces it
// with a `startupProbe`, which holds the liveness probe off until `/health`
// answers for the first time — the two are independent, and either alone is
// enough to prevent the restart.

let telemetryBootstrapDeadline = Swift.Duration.seconds(10)

/// A telemetry bootstrap that outlived ``telemetryBootstrapDeadline``.
struct TelemetryBootstrapTimeout: Error, CustomStringConvertible {
  let deadline: Swift.Duration
  var description: String { "telemetry bootstrap exceeded its \(deadline) budget" }
}

/// Runs `operation`, throwing ``TelemetryBootstrapTimeout`` if it outlives `deadline`.
///
/// Structured rather than detached, so whichever branch loses is cancelled and
/// the group cannot outlive the winner. That only works because the exchange
/// runs on AsyncHTTPClient, which honours cancellation — a `URLSession` call on
/// Linux would not, and would need `URLRequest.timeoutInterval` instead.
func withDeadline<T: Sendable>(
  _ deadline: Swift.Duration,
  _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
  try await withThrowingTaskGroup(of: T.self) { group in
    group.addTask { try await operation() }
    group.addTask {
      try await Task.sleep(for: deadline)
      throw TelemetryBootstrapTimeout(deadline: deadline)
    }
    defer { group.cancelAll() }
    return try await group.next()!
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
//
// This is a **one-shot**, and fail-soft here means *permanently* soft: swift-log
// can only be bootstrapped once per process, so a batcher that does not exist by
// the time `LoggingSystem.bootstrap` runs can never be added later. If the
// exchange fails or times out, this pod ships no logs and no metrics for the
// rest of its life — `/health` and `/file` keep working, because `OCIStore`
// builds its own signer lazily on the first request and will happily succeed.
// Recovery is a pod restart. `GET /telemetry` reports `failed` (as opposed to
// `disabled`) precisely so an operator can tell the two apart.

var telemetrySigner: OKEWorkloadIdentitySigner?
var telemetryRegion: Region?
var logBatcher: OCILogBatcher?
/// Stashed rather than logged: there is no logging system yet.
var telemetryBootstrapError: (any Error)?

if logId != nil || (metricsNamespace != nil && compartmentId != nil) {
  do {
    // One RPST, three uses: Object Storage, PutLogs and PostMetricData.
    let signer = try await withDeadline(telemetryBootstrapDeadline) {
      try await OKEWorkloadIdentitySigner.fromWorkloadIdentity()
    }
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
          // shutdown: 3 attempts × 5s timeout + 10s of backoff ≈ 25s worst case.
          // That plus the metrics drain is why `deploy/swift-oke.yaml` raises
          // `terminationGracePeriodSeconds` to 45 — Kubernetes' default of 30s
          // would SIGKILL a slow final flush.
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
    """
    telemetry bootstrap failed — console logging only, no OCI logs or metrics \
    for the lifetime of this pod (restart to retry)
    """,
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
    //
    // Which also means the transport bound is ours to supply. `MonitoringClient`
    // defaults to `HTTPClient.live`, so an unanswered `PostMetricData` inherits
    // `URLSession`'s 60-second default — and `OCIMetricsFactory.shutdown()`
    // performs up to two of them (it awaits the in-flight step tick, then
    // flushes), which alone would outlast the pod's 45s grace period. Bounding
    // it here is exactly what `OCILogBatcher` does internally for `PutLogs`, and
    // for the same reason: on Linux the `URLSession` async shim ignores
    // cancellation, so `timeoutInterval` is the only bound that actually binds.
    let boundedTransport = OCIKit.HTTPClient { request in
      var request = request
      request.timeoutInterval = 5
      return try await OCIKit.HTTPClient.live.data(request)
    }
    let monitoring = try MonitoringClient(
      region: region,
      signer: signer,
      httpClient: boundedTransport
    )
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
      // Payload volume, counted where the byte count is actually known — the
      // middleware upstack only sees a `Response`, whose body is a stream it must
      // not consume. Dimensioned by bucket alone: the object *name* is the caller's
      // to choose, so labelling by it would mint one metric stream per distinct
      // URL ever requested. Bucket is a single configured value per deployment.
      //
      // "Cumulative" is the query's job, not the counter's: the backend exports a
      // counter as the per-step delta, so the running total is
      // `bytes_served_total[1m].sum()` summed over whatever window you ask for.
      // That is what you want across restarts — a monotonic in-process total would
      // reset to zero every rollout and read as a cliff.
      Counter(label: "bytes_served_total", dimensions: [("bucket", bucket)])
        .increment(by: data.count)
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

/// The method names allowed to appear as a `method` dimension value; anything
/// else is folded into `"other"`.
///
/// swift-nio's HTTP/1 decoder only ever yields methods from llhttp's fixed
/// table, so a nonsense token (`curl -X ZZZ`) is rejected by the parser and
/// never reaches this middleware — but that table still holds ~40 entries
/// (`PROPFIND`, `MKCALENDAR`, `UNSUBSCRIBE`, …), each of which would otherwise
/// mint its own stream per route and status class. Folding is a one-line way to
/// keep the dimension's cardinality equal to its usefulness.
enum RecordedHTTPMethod {
  static let known: Set<String> = ["GET", "HEAD", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"]

  static func label(for method: String) -> String {
    known.contains(method) ? method : "other"
  }
}

/// Records one counter and one timer per request.
///
/// The dimension set is deliberately **bounded**, and every element of it is a
/// separate decision: the route *template* (`/files/:name` — never the expanded
/// path), the HTTP method *folded through an allow-list*
/// (``RecordedHTTPMethod``), and the status *class* rather than the exact code.
/// Every distinct combination of dimension values mints its own metric stream in
/// OCI Monitoring, so a dimension carrying user input — an object name, a
/// request id, a raw URI — mints an unbounded number of them: expensive,
/// unqueryable, and the single easiest way to make a metrics bill interesting.
/// `app` and `pod` are added to every stream for free by the factory's
/// `commonDimensions`.
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
    // Hummingbird's `NotFoundResponder` stamps `endpointPath` with `"NotFound"`
    // before this runs — unmatched requests still traverse the middleware chain —
    // so the fallback is belt-and-braces rather than a real bucket.
    let dimensions = [
      ("route", context.endpointPath ?? "NotFound"),
      ("method", RecordedHTTPMethod.label(for: request.method.rawValue)),
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
//
// It is served on the same public listener as everything else and has no auth,
// so it reports the *shape* of a failure, not its payload:
// `statistics(redactingErrors:)` reduces `log.lastFlushError` to the error's
// case name. The full text — which for an HTTP failure is the service's raw
// response body, `opc-request-id` and all — stays in `kubectl logs`. Add auth,
// or a second listener, before exposing anything richer than this.
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
  // `failed` is worth spelling out: the bootstrap runs once, at startup, and is
  // never retried, so this state persists until the pod is replaced.
  if (logId != nil && telemetry.batcher == nil) || (metricsConfigured && telemetry.metrics == nil) {
    lines.append(
      "note: 'failed' = the one-shot startup bootstrap did not complete; it is never retried — "
        + "restart the pod, and see kubectl logs for the reason"
    )
  }
  let stats = await telemetry.statistics(redactingErrors: true)
  for (key, value) in stats.sorted(by: { $0.key < $1.key }) {
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
