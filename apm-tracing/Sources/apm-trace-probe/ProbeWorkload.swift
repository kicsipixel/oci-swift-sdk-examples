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
import Logging
import ServiceLifecycle
import Tracing

/// The traced "application" — one server span with a child, standing in for whatever
/// real work a VM / OKE / Container Instances workload does.
///
/// It runs as a `ServiceLifecycle` service so it shares a lifecycle with the swift-otel
/// exporter service: the group starts both, and when this one returns the group shuts
/// down gracefully, which is what flushes the batch span processor. That flush is the
/// point — a process that exits without it loses every span still in the buffer.
struct ProbeWorkload: Service {

  /// The probe's own logger (not the tracing pipeline's diagnostic logger).
  let logger: Logger

  /// The delay before the first span, giving the exporter service time to start.
  private let startupGrace = Duration.milliseconds(250)

  /// Emits one trace, then returns so the service group can shut down and flush.
  func run() async throws {
    try await Task.sleep(for: startupGrace)

    try await withSpan("apm-trace-probe request", ofKind: .server) { span in
      span.attributes["ocikit.example"] = "apm-trace-probe"
      span.attributes["ocikit.runtime"] = "standalone"

      // The `traceparent` of the span in flight — logged so the trace can be read back
      // with `oci apm-traces trace trace get --trace-key <trace id>`.
      var carrier: [String: String] = [:]
      InstrumentationSystem.instrument.inject(span.context, into: &carrier, using: HeaderDictionaryInjector())
      logger.info(
        "started root span",
        metadata: ["traceparent": .string(carrier["traceparent"] ?? "<no traceparent>")]
      )

      try await withSpan("apm-trace-probe work") { child in
        child.attributes["ocikit.step"] = "work"
        try await Task.sleep(for: .milliseconds(25))
      }
    }

    logger.info("trace emitted; shutting down to flush the span processor")
  }
}
