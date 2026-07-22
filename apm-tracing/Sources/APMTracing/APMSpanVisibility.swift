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

/// Which of an APM domain's two span-ingestion paths spans are uploaded to.
///
/// An APM domain issues two data keys. The public key authenticates uploads to the
/// `public` path and is safe to hand to a browser agent or, as OCI Functions does, to
/// inject into a container's environment; the private key authenticates the `private`
/// path and is the only key that also unlocks OTLP *metrics* ingestion.
///
/// This mirrors `APMCollectorEndpoint.Visibility` in `OCIKitFunctions`, kept separate
/// so the reusable part of this example does not pull the Functions FDK (and SwiftNIO)
/// into a workload that is not a function.
public enum APMSpanVisibility: String, Sendable, CaseIterable {
  /// The `opentelemetry/public/v1/traces` path, authenticated with the domain's
  /// public data key.
  case publicSpan = "public"
  /// The `opentelemetry/private/v1/traces` path, authenticated with the domain's
  /// private data key.
  case privateSpan = "private"
}
