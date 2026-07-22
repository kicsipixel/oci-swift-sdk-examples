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

/// A swift-distributed-tracing `Injector` over a plain `[String: String]` carrier.
///
/// A real workload uses this to propagate the current trace onto outbound requests;
/// this example also uses it to read the `traceparent` of the span it just started, so
/// the trace can be looked up afterwards with
/// `oci apm-traces trace trace get --trace-key <trace id>`.
public struct HeaderDictionaryInjector: Injector {

  /// The carrier this injector writes into.
  public typealias Carrier = [String: String]

  /// Creates an injector.
  public init() {}

  /// Stores `value` under `key` in the carrier.
  public func inject(_ value: String, forKey key: String, into carrier: inout Carrier) {
    carrier[key] = value
  }
}
