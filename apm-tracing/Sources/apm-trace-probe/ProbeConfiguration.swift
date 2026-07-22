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
import OTel

/// The probe's configuration, read entirely from the environment.
///
/// Nothing about a tenancy is compiled in: the APM domain's data-upload endpoint and
/// its data key are deployment inputs. On a VM, in OKE, or on Container Instances the
/// recommended source for the key is a Vault secret read at startup with OCIKit's
/// `SecretsClient.getSecretBundle` under the workload's injected principal; passing it
/// through the environment, as here, keeps the example free of any OCI dependency.
struct ProbeConfiguration: Sendable {

  /// `APM_DATA_UPLOAD_ENDPOINT` — the APM domain's `dataUploadEndpoint`.
  let dataUploadEndpoint: URL

  /// `APM_DATA_KEY` — the APM data key matching ``visibility``.
  let dataKey: String

  /// `APM_SPAN_VISIBILITY` — `public` (default) or `private`.
  let visibility: APMSpanVisibility

  /// `APM_SERVICE_NAME` — the `service.name` spans are grouped under.
  let serviceName: String

  /// `APM_DIAGNOSTIC_LOG_LEVEL` — swift-otel's own log level. Raise it to `debug` to
  /// see the exporter log the HTTP status code APM replied with.
  let diagnosticLogLevel: OTel.Configuration.LogLevel

  /// The OTLP/HTTP traces endpoint these settings resolve to.
  var otlpTracesURL: URL {
    APMTraceExporter.otlpTracesURL(dataUploadEndpoint: dataUploadEndpoint, visibility: visibility)
  }

  /// Reads the configuration, throwing ``ProbeConfigurationError`` on anything missing
  /// or malformed rather than falling back to a guess.
  static func fromEnvironment(_ environment: [String: String]) throws -> ProbeConfiguration {
    let rawEndpoint = try required("APM_DATA_UPLOAD_ENDPOINT", in: environment)
    guard let dataUploadEndpoint = URL(string: rawEndpoint), dataUploadEndpoint.scheme != nil else {
      throw ProbeConfigurationError.invalidVariable(
        name: "APM_DATA_UPLOAD_ENDPOINT",
        value: rawEndpoint,
        expected: "an absolute https URL"
      )
    }

    let dataKey = try required("APM_DATA_KEY", in: environment)

    let visibility: APMSpanVisibility
    if let rawVisibility = environment["APM_SPAN_VISIBILITY"], !rawVisibility.isEmpty {
      guard let parsed = APMSpanVisibility(rawValue: rawVisibility.lowercased()) else {
        throw ProbeConfigurationError.invalidVariable(
          name: "APM_SPAN_VISIBILITY",
          value: rawVisibility,
          expected: APMSpanVisibility.allCases.map(\.rawValue).joined(separator: " or ")
        )
      }
      visibility = parsed
    }
    else {
      visibility = .publicSpan
    }

    let serviceName = environment["APM_SERVICE_NAME"].flatMap { $0.isEmpty ? nil : $0 } ?? "ocikit-apm-trace-probe"

    let diagnosticLogLevel: OTel.Configuration.LogLevel
    if let rawLevel = environment["APM_DIAGNOSTIC_LOG_LEVEL"], !rawLevel.isEmpty {
      guard let parsed = Self.logLevel(named: rawLevel) else {
        throw ProbeConfigurationError.invalidVariable(
          name: "APM_DIAGNOSTIC_LOG_LEVEL",
          value: rawLevel,
          expected: "error, warning, info, debug or trace"
        )
      }
      diagnosticLogLevel = parsed
    }
    else {
      diagnosticLogLevel = .info
    }

    return ProbeConfiguration(
      dataUploadEndpoint: dataUploadEndpoint,
      dataKey: dataKey,
      visibility: visibility,
      serviceName: serviceName,
      diagnosticLogLevel: diagnosticLogLevel
    )
  }

  /// Returns a non-empty environment value, or throws.
  private static func required(_ name: String, in environment: [String: String]) throws -> String {
    guard let value = environment[name], !value.isEmpty else {
      throw ProbeConfigurationError.missingVariable(name: name)
    }
    return value
  }

  /// Maps a level name onto swift-otel's diagnostic log level, which is a struct with
  /// no string-based initialiser.
  private static func logLevel(named name: String) -> OTel.Configuration.LogLevel? {
    switch name.lowercased() {
    case "error": return .error
    case "warning", "warn": return .warning
    case "info": return .info
    case "debug": return .debug
    case "trace": return .trace
    default: return nil
    }
  }
}
