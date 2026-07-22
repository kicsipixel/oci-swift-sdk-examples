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
import OTel
import ServiceLifecycle

/// Exports one OpenTelemetry trace to an OCI APM domain over OTLP/HTTP.
///
/// This is the shape any long-running Swift workload uses on a Compute VM, in OKE, or
/// on Container Instances: bootstrap swift-otel against the APM domain's OTLP traces
/// endpoint with the domain's data key, run the returned service alongside the
/// application's own, and instrument the code with plain `withSpan`.
///
/// Nothing here is OCI-specific beyond the endpoint and the `Authorization` header —
/// APM authenticates span uploads with the data key, so no signer and no IAM policy are
/// involved on this path.
@main
struct APMTraceProbe {

  static func main() async throws {
    var logger = Logger(label: "apm-trace-probe")
    logger.logLevel = .debug

    let configuration = try ProbeConfiguration.fromEnvironment(ProcessInfo.processInfo.environment)
    logger.info(
      "exporting spans to APM",
      metadata: [
        "endpoint": .string(configuration.otlpTracesURL.absoluteString),
        "visibility": .string(configuration.visibility.rawValue),
        "service.name": .string(configuration.serviceName),
      ]
    )

    var otelConfiguration = APMTraceExporter.configuration(
      otlpTracesURL: configuration.otlpTracesURL,
      dataKey: configuration.dataKey,
      serviceName: configuration.serviceName
    )
    otelConfiguration.diagnosticLogLevel = configuration.diagnosticLogLevel

    // Bootstraps the process-global tracing system and returns the exporter's
    // background service. Spans recorded before the service runs are buffered.
    let observability = try OTel.bootstrap(configuration: otelConfiguration)

    // The workload terminates the group when it finishes, and the group's graceful
    // shutdown is what flushes buffered spans to APM.
    let serviceGroup = ServiceGroup(
      configuration: ServiceGroupConfiguration(
        services: [
          ServiceGroupConfiguration.ServiceConfiguration(service: observability),
          ServiceGroupConfiguration.ServiceConfiguration(
            service: ProbeWorkload(logger: logger),
            successTerminationBehavior: .gracefullyShutdownGroup
          ),
        ],
        logger: logger
      )
    )
    try await serviceGroup.run()
    logger.info("done")
  }
}
