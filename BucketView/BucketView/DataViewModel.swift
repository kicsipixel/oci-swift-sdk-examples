//
//  DataViewModel.swift
//  BucketView
//
//  Created by Szabolcs Tóth on 03.10.2025.
//
//  This file is part of FileLift and is licensed under the MIT License.
//  Copyright © 2025 Szabolcs Tóth.
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in all
//  copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
//  SOFTWARE.

import OCIKit
import SwiftUI

protocol DataViewModelProtocol: Observable {
  var namespace: String { get set }
  var buckets: [BucketSummary] { get set }
  var objects: [ObjectSummary] { get set }
  var isCompartmentIdSet: Bool { get set }

  func getNamespace() async throws
  func listBuckets() async throws
  func listObjects(bucketName: String) async throws
  func checkCompartmentId()
}

@Observable @MainActor
final class DataViewModel: DataViewModelProtocol {
  // Private properties
  // Properties
  let client: ObjectStorageClient
  var namespace: String = ""
  var buckets = [BucketSummary]()
  var objects = ListObjects(nextStartWith: nil, objects: [], prefixes: nil).objects
  var isCompartmentIdSet = false

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
  // TODO: Error handling is missing.
  func listBuckets() async throws {
    buckets = []
    var compartmentId: String {
      UserDefaults.standard.string(forKey: "compartmentId") ?? ""
    }
    buckets =
      try await client.listBuckets(namespaceName: namespace, compartmentId: compartmentId)

    // Use the first bucket
    if let firstBucket = buckets.first {
      try await listObjects(bucketName: firstBucket.name)
    }
    else {
      objects = []
    }
  }

  // MARK: - Lists object in the selected bucket
  func listObjects(bucketName: String) async throws {
    let defaults = UserDefaults.standard
    var fields: [Field] = [.name, .size, .timeCreated, .timeModified]

    if defaults.bool(forKey: "etag") {
      fields.append(.etag)
    }
    if defaults.bool(forKey: "md5") {
      fields.append(.md5)
    }
    if defaults.bool(forKey: "storagetier") {
      fields.append(.storageTier)
    }
    if defaults.bool(forKey: "archivalstate") {
      fields.append(.archivalState)
    }

    objects = []
    do {
      if fields.isEmpty {
        objects = try await client.listObjects(namespaceName: namespace, bucketName: bucketName).objects
      }
      else {
        objects = try await client.listObjects(namespaceName: namespace, bucketName: bucketName, fields: fields).objects
      }
    }
    catch {
      // TODO: Handle error message
      print("\(error)")
    }
  }

  func checkCompartmentId() {
    isCompartmentIdSet = UserDefaults.standard.string(forKey: "compartmentId")?.isEmpty == true
  }
}

private struct DataViewModelKey: EnvironmentKey {
    static let defaultValue: DataViewModelProtocol = MockDataViewModel()
}

extension EnvironmentValues {
    var dataViewModel: DataViewModelProtocol {
        get { self[DataViewModelKey.self] }
        set { self[DataViewModelKey.self] = newValue }
    }
}
