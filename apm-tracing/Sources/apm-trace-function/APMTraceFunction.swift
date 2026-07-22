//===----------------------------------------------------------------------===//
//
// This source file is part of the oci-swift-sdk open source project
//
// Copyright (c) 2026 Ilia Sazonov and the oci-swift-sdk project authors
// Licensed under MIT License
//
// See LICENSE for license information
// See CONTRIBUTORS.md for the list of oci-swift-sdk project authors
//
// SPDX-License-Identifier: MIT License
//
//===----------------------------------------------------------------------===//

import APMTracing
import Foundation
import Logging
import OCIKitFunctions
import OTel
import ServiceLifecycle

/// An OCI Function that adds its own OpenTelemetry spans to the trace the Functions
/// platform started for the invocation.
///
/// The whole configuration comes from what the platform injects when tracing is enabled
/// on the application and the function — nothing is compiled in and nothing has to be
/// deployed as function configuration:
///
/// - `OCI_TRACING_ENABLED` / `OCI_TRACE_COLLECTOR_URL` become
///   `TracingContext.collectorEndpoint`, which retargets the injected legacy Zipkin URL
///   onto the same APM domain's OTLP/HTTP traces path and lifts the embedded **public**
///   data key out of it.
/// - `FN_APP_NAME` / `FN_FN_NAME` become `TracingContext.serviceName`, the conventional
///   `<app>::<function>` name spans are grouped under.
/// - The per-invocation `X-B3-TraceId` / `X-B3-SpanId` headers become the parent of the
///   handler's span (see ``TracedFunctionService``).
///
/// With tracing disabled the function still serves, untraced.
@main
struct APMTraceFunction {

  /// How long the span processor waits before exporting a batch.
  ///
  /// The OTel default is 5 seconds, which is longer than a short invocation: OCI freezes
  /// a function container once it responds, so a batch still sitting in the buffer is
  /// not sent until the container thaws for the next invocation. A short delay exports
  /// while the container is still running, at the cost of one HTTP request per
  /// invocation.
  private static let batchScheduleDelay = Duration.milliseconds(200)

  /// How long graceful shutdown may take before it escalates to task cancellation.
  ///
  /// Only a backstop — `TracedFunctionService` returns as soon as shutdown is signalled —
  /// but it guarantees the process can never hang waiting for a service to stop.
  private static let maximumGracefulShutdownDuration = Duration.seconds(5)

  static func main() async throws {
    var logger = Logger(label: "apm-trace-function")
    logger.logLevel = .info

    let runtime = RuntimeContext.fromEnvironment()
    // No invocation headers yet — this reads only the container-wide tracing
    // configuration, which is what the exporter needs at startup.
    let tracing = TracingContext(runtime: runtime, headers: FunctionHeaders())

    guard let endpoint = tracing.collectorEndpoint else {
      logger.warning(
        "tracing is disabled or the collector URL was unusable; serving untraced",
        metadata: [
          "OCI_TRACING_ENABLED": .string(tracing.isEnabled ? "1" : "0"),
          "collectorURLPresent": .string(tracing.traceCollectorURL == nil ? "false" : "true"),
        ]
      )
      try await FunctionRuntime.serve(logger: logger) { context, request in
        .text(request.string ?? "")
      }
      return
    }

    let serviceName = tracing.serviceName ?? "ocikit-apm-trace-function"
    logger.info(
      "exporting spans to APM",
      metadata: [
        "endpoint": .string(endpoint.otlpTracesURL.absoluteString),
        "visibility": .string(endpoint.visibility.rawValue),
        "service.name": .string(serviceName),
      ]
    )

    var configuration = APMTraceExporter.configuration(
      otlpTracesURL: endpoint.otlpTracesURL,
      dataKey: endpoint.dataKey,
      serviceName: serviceName,
      resourceAttributes: Self.resourceAttributes(from: runtime)
    )
    configuration.traces.batchSpanProcessor.scheduleDelay = Self.batchScheduleDelay

    let observability = try OTel.bootstrap(configuration: configuration)

    // The exporter shares the FDK server's lifecycle so a container shutdown flushes
    // whatever spans are still buffered. Order matters: services shut down in reverse,
    // so the serve loop stops first (see `TracedFunctionService.run()`) and the
    // exporter flushes afterwards.
    var groupConfiguration = ServiceGroupConfiguration(
      services: [
        ServiceGroupConfiguration.ServiceConfiguration(service: observability),
        ServiceGroupConfiguration.ServiceConfiguration(service: TracedFunctionService(logger: logger)),
      ],
      gracefulShutdownSignals: [.sigterm, .sigint],
      logger: logger
    )
    // Backstop: if a service ever fails to return on graceful shutdown, escalate to
    // cancellation rather than hanging until the platform's SIGKILL.
    groupConfiguration.maximumGracefulShutdownDuration = Self.maximumGracefulShutdownDuration

    let serviceGroup = ServiceGroup(configuration: groupConfiguration)
    try await serviceGroup.run()
  }

  /// OpenTelemetry resource attributes describing the function, using the FaaS
  /// semantic-convention keys.
  private static func resourceAttributes(from runtime: RuntimeContext) -> [String: String] {
    var attributes: [String: String] = ["cloud.provider": "oracle_cloud", "cloud.platform": "oci_functions"]
    if let functionName = runtime.functionName { attributes["faas.name"] = functionName }
    if let functionID = runtime.functionID { attributes["faas.id"] = functionID }
    if let appName = runtime.appName { attributes["oci.fn.app_name"] = appName }
    return attributes
  }
}
