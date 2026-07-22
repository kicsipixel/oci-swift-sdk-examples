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

/// What the function returns to its caller: enough to find the invocation's trace in
/// APM without reading the function's logs.
struct FunctionInvocationSummary: Encodable {

  /// The 64-bit `X-B3-TraceId` the platform injected, or `nil` when tracing is off.
  let b3TraceID: String?

  /// The W3C `traceparent` of the span this invocation recorded — its trace id is the
  /// left-padded 128-bit form of ``b3TraceID``.
  let otelTraceparent: String?

  /// The conventional `<app>::<function>` tracing service name, from `TracingContext`.
  let serviceName: String?

  /// The request body, echoed back so the example is also a working function.
  let echo: String?
}
