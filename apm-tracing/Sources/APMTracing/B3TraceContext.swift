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

import Tracing

/// A Zipkin B3 trace context normalised to W3C Trace Context widths, so an
/// OpenTelemetry tracer can adopt it as the parent of the spans it starts.
///
/// The OCI Functions platform propagates trace context in Zipkin's B3 headers, and its
/// trace ids are **64-bit** (16 hex characters). OpenTelemetry trace ids are
/// **128-bit** (32 hex characters), so the B3 id is left-padded with zeros — the
/// conversion Zipkin itself specifies, and the reason a Functions-started trace and
/// the spans a Swift handler adds to it end up in the same APM trace.
///
/// swift-otel 1.5.0 ships no B3 propagator (`OTel.Configuration.Propagator.b3` and
/// `.b3Multi` trap with "Swift OTel does not support the B3 … propagator"), so this
/// type renders the normalised ids as a W3C `traceparent` header value and feeds that
/// through the standard, supported `traceContext` propagator:
///
/// ```swift
/// let tracing = context.tracing                               // OCIKitFunctions
/// let parent = B3TraceContext(
///   traceID: tracing.traceId,
///   spanID: tracing.spanId,
///   isSampled: tracing.isSampled
/// )
/// try await withSpan("handle", context: parent?.serviceContext ?? .topLevel) { span in
///   // …
/// }
/// ```
public struct B3TraceContext: Sendable, Equatable {

  /// The number of hex characters in a W3C/OpenTelemetry trace id.
  private static let traceIDWidth = 32

  /// The number of hex characters in a W3C/OpenTelemetry span id.
  private static let spanIDWidth = 16

  /// The W3C Trace Context header carrying the sampled parent span.
  private static let traceparentHeaderName = "traceparent"

  /// The only W3C Trace Context version defined so far.
  private static let traceparentVersion = "00"

  /// The trace id, lower-case hex, left-padded to 128 bits.
  public let traceID: String

  /// The parent span id, lower-case hex, 64 bits.
  public let spanID: String

  /// Whether the incoming trace was sampled — the `sampled` flag of the rendered
  /// `traceparent`.
  public let isSampled: Bool

  /// Normalises a B3 trace context, failing when either identifier is absent or not
  /// usable as a W3C one.
  ///
  /// - Parameters:
  ///   - traceID: The `X-B3-TraceId` value: 16 or 32 hex characters. Shorter values
  ///     are accepted and left-padded too.
  ///   - spanID: The `X-B3-SpanId` value: up to 16 hex characters.
  ///   - isSampled: The `X-B3-Sampled` decision. OCI Functions sends no sampling
  ///     header on a direct invoke, and `TracingContext` reports `true` in that case.
  /// - Returns: `nil` when an identifier is missing, empty, longer than its W3C width,
  ///   not hex, or all zeros (which W3C defines as invalid).
  public init?(traceID: String?, spanID: String?, isSampled: Bool = true) {
    guard
      let traceID,
      let spanID,
      let normalisedTraceID = Self.leftPaddedHex(traceID, width: Self.traceIDWidth),
      let normalisedSpanID = Self.leftPaddedHex(spanID, width: Self.spanIDWidth)
    else {
      return nil
    }
    self.traceID = normalisedTraceID
    self.spanID = normalisedSpanID
    self.isSampled = isSampled
  }

  /// The context rendered as a W3C `traceparent` header value, e.g.
  /// `00-0000000000000000d2d1f2b0e5a6c3f4-d2d1f2b0e5a6c3f4-01`.
  public var traceparentHeaderValue: String {
    "\(Self.traceparentVersion)-\(traceID)-\(spanID)-\(isSampled ? "01" : "00")"
  }

  /// The context as a `ServiceContext`, ready to pass to `withSpan(_:context:)` so the
  /// spans started under it become children of the platform's span.
  ///
  /// This goes through `InstrumentationSystem.instrument`, so it only yields a populated
  /// context after a tracer has been bootstrapped with the `traceContext` propagator
  /// enabled — swift-otel's default.
  public var serviceContext: ServiceContext {
    var context = ServiceContext.topLevel
    InstrumentationSystem.instrument.extract(
      [Self.traceparentHeaderName: traceparentHeaderValue],
      into: &context,
      using: HeaderDictionaryExtractor()
    )
    return context
  }

  /// Lower-cases, validates and left-pads a hex identifier to `width` characters.
  static func leftPaddedHex(_ value: String, width: Int) -> String? {
    guard !value.isEmpty, value.count <= width, value.allSatisfy(\.isHexDigit) else { return nil }
    let padded = String(repeating: "0", count: width - value.count) + value.lowercased()
    // An all-zero identifier is invalid per the W3C Trace Context specification.
    guard padded.contains(where: { $0 != "0" }) else { return nil }
    return padded
  }
}
