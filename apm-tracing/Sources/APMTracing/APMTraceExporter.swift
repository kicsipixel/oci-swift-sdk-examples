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

import Foundation
import OTel

/// The whole OCI APM tracing recipe: where spans go, and how swift-otel must be
/// configured to send them there.
///
/// OCI Application Performance Monitoring is the one OCI service that speaks
/// OpenTelemetry natively. Each APM domain exposes a `dataUploadEndpoint` — a host of
/// the form `https://<domain>.apm-agt.<region>.oci.oraclecloud.com` — and ingests
/// OTLP/HTTP spans at `/<version>/opentelemetry/{public|private}/v1/traces` on it.
/// Uploads are authenticated with an APM **data key**, not with OCI request signing:
/// no signer, no IAM policy, and no OCIKit code sit on this path.
///
/// ```swift
/// let tracesURL = APMTraceExporter.otlpTracesURL(dataUploadEndpoint: dataUploadEndpoint)
/// let configuration = APMTraceExporter.configuration(
///   otlpTracesURL: tracesURL,
///   dataKey: dataKey,
///   serviceName: "orders"
/// )
/// let observability = try OTel.bootstrap(configuration: configuration)
/// ```
public enum APMTraceExporter {

  /// The APM ingestion API version, the only one published so far and the one the
  /// Functions platform's injected collector URL carries.
  public static let defaultAPIVersion = "20200101"

  /// The path segment introducing APM's OTLP ingestion paths.
  private static let openTelemetrySegment = "opentelemetry"

  /// The OTLP/HTTP path segments that follow the visibility segment.
  private static let tracesSegments = ["v1", "traces"]

  /// Composes an APM domain's OTLP/HTTP traces endpoint from its data-upload endpoint.
  ///
  /// - Parameters:
  ///   - dataUploadEndpoint: The APM domain's `dataUploadEndpoint`, as reported by
  ///     `oci apm-control-plane apm-domain get`.
  ///   - visibility: Which span path to post to. Defaults to
  ///     ``APMSpanVisibility/publicSpan``.
  ///   - apiVersion: The ingestion API version segment. Defaults to
  ///     ``defaultAPIVersion``.
  /// - Returns: e.g.
  ///   `https://<domain>.apm-agt.<region>.oci.oraclecloud.com/20200101/opentelemetry/public/v1/traces`.
  public static func otlpTracesURL(
    dataUploadEndpoint: URL,
    visibility: APMSpanVisibility = .publicSpan,
    apiVersion: String = APMTraceExporter.defaultAPIVersion
  ) -> URL {
    let segments = [apiVersion, Self.openTelemetrySegment, visibility.rawValue] + Self.tracesSegments
    return segments.reduce(dataUploadEndpoint) { $0.appending(path: $1) }
  }

  /// Builds the swift-otel configuration that exports spans — and only spans — to an
  /// APM domain.
  ///
  /// Logs and metrics are switched off deliberately:
  ///
  /// - APM exposes **no OTLP logs endpoint at all**. Application logs belong in OCI
  ///   Logging, which OCIKit's `OCILogHandler` writes to over `PutLogs`.
  /// - APM's OTLP metrics endpoint (`/<version>/opentelemetry/v1/metrics`) accepts the
  ///   **private** data key only, and lands the result in OCI Monitoring under the
  ///   `oracle_apm_monitoring` namespace. OCIKit's `OCIMetricsFactory` posts to OCI
  ///   Monitoring directly instead, under an injected OCI principal.
  ///
  /// - Parameters:
  ///   - otlpTracesURL: The endpoint from ``otlpTracesURL(dataUploadEndpoint:visibility:apiVersion:)``,
  ///     or the `otlpTracesURL` of an `APMCollectorEndpoint` parsed out of what the
  ///     Functions platform injected.
  ///   - dataKey: The APM data key matching the endpoint's visibility. Read it from a
  ///     Vault secret with `SecretsClient.getSecretBundle`, or — on Functions — take
  ///     it from the injected collector URL. Never hard-code it.
  ///   - serviceName: The `service.name` resource attribute; this is the name spans
  ///     are grouped under in Trace Explorer.
  ///   - resourceAttributes: Extra OpenTelemetry resource attributes to stamp on every
  ///     span, e.g. `["deployment.environment": "prod"]`.
  /// - Returns: A configuration ready for `OTel.bootstrap(configuration:)`.
  public static func configuration(
    otlpTracesURL: URL,
    dataKey: String,
    serviceName: String,
    resourceAttributes: [String: String] = [:]
  ) -> OTel.Configuration {
    var configuration = OTel.Configuration.default
    configuration.serviceName = serviceName
    configuration.resourceAttributes = resourceAttributes
    configuration.logs.enabled = false
    configuration.metrics.enabled = false

    configuration.traces.enabled = true
    configuration.traces.exporter = .otlp
    configuration.traces.otlpExporter.protocol = .httpProtobuf
    // Assigning `endpoint` marks it as explicitly set, so swift-otel POSTs to this URL
    // verbatim rather than treating it as a base and appending `/v1/traces` to it.
    configuration.traces.otlpExporter.endpoint = otlpTracesURL.absoluteString
    // APM authenticates span uploads with the data key alone.
    configuration.traces.otlpExporter.headers = [("authorization", "dataKey \(dataKey)")]
    return configuration
  }
}
