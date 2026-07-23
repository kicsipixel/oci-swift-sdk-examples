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

/// A swift-distributed-tracing `Extractor` over a plain `[String: String]` carrier.
///
/// Propagators read trace context out of a carrier through an extractor; a dictionary
/// is the simplest carrier there is, and it is all ``B3TraceContext/serviceContext``
/// needs to hand a synthesised `traceparent` to the bootstrapped propagator.
public struct HeaderDictionaryExtractor: Extractor {

  /// The carrier this extractor reads from.
  public typealias Carrier = [String: String]

  /// Creates an extractor.
  public init() {}

  /// Returns the value stored under `key`, or `nil` when the carrier has no such entry.
  public func extract(key: String, from carrier: Carrier) -> String? {
    carrier[key]
  }
}
