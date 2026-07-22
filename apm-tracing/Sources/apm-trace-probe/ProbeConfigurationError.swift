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

/// Why the probe could not read its configuration out of the environment.
enum ProbeConfigurationError: Error, CustomStringConvertible {

  /// A required environment variable is unset or empty.
  case missingVariable(name: String)

  /// An environment variable is set to something unusable.
  case invalidVariable(name: String, value: String, expected: String)

  var description: String {
    switch self {
    case .missingVariable(let name):
      return "environment variable \(name) is required but unset or empty"
    case .invalidVariable(let name, let value, let expected):
      return "environment variable \(name) has invalid value '\(value)'; expected \(expected)"
    }
  }
}
