//
//  DataViewModel.swift
//  FileLift
//
//  Created by Szabolcs Tóth on 03.10.2025.
//  Copyright © 2025 Szabolcs Tóth. All rights reserved.
//

import OCIKit
import SwiftUI

@Observable @MainActor
final class DataViewModel {
  // Private properties
  // Properties
  let client: ObjectStorageClient
  var namespace: String = ""
  var buckets = [BucketSummary]()

  init() throws {
    let env = ProcessInfo.processInfo.environment
    let ociConfigFilePath =
      env["OCI_CONFIG_FILE"] ?? "\(NSHomeDirectory())/.oci/config"
    let ociProfileName = env["OCI_PROFILE"] ?? "DEFAULT"
    let regionId = try extractUserRegion(
      from: ociConfigFilePath,
      profile: ociProfileName
    )
    let region = Region.from(regionId: regionId ?? "") ?? .iad
    let signer = try APIKeySigner(
      configFilePath: ociConfigFilePath,
      configName: ociProfileName
    )
    client = try ObjectStorageClient(region: region, signer: signer)
  }

  // A non-throwing mock initializer or static property for preview purposes.
  static var preview: DataViewModel {
    let mock = try! DataViewModel()
    // optionally stub any values here
    return mock
  }

  // MARK: - Gets namespace of the user's object storage
  func getNamespace() async throws {
    namespace = try await client.getNamespace()
  }

  // MARK: - Lists buckets in the user given compartment
  func listBuckets() async throws {
    var compartmentId: String {
      UserDefaults.standard.string(forKey: "compartmentId") ?? ""
    }
    buckets = try await client.listBuckets(namespaceName: namespace.replacingOccurrences(of: "\"", with: ""), compartmentId: compartmentId)
  }

  // MARK: - Pusts object/file into the bucket
  func putObject(filePath: String) async throws {
    let url = URL(fileURLWithPath: filePath)
    let fileData = try Data(contentsOf: url)
    try await client.putObject(
      namespaceName: namespace.replacingOccurrences(of: "\"", with: ""),
      bucketName: UserDefaults.standard.string(forKey: "selection")!,
      objectName: "\(url.lastPathComponent)",
      putObjectBody: fileData
    )
  }
}
