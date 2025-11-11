//
//  DataViewModel.swift
//  FileLift
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
  var isUploading: Bool { get set }
  var uploadSuccessMessage: String? { get set }

  func getNamespace() async throws
  func listBuckets() async throws
  func putObject(filePath: String) async throws
  func showUploadSuccessMessage(_ text: String)
}


@Observable @MainActor
final class DataViewModel: DataViewModelProtocol {
  // Properties
  let client: ObjectStorageClient
  var namespace: String = ""
  var buckets = [BucketSummary]()
  var isUploading = false
  var uploadSuccessMessage: String? = nil

  // MARK: - Initializer
    init?() {
        do {
          let env = ProcessInfo.processInfo.environment
          let ociConfigFilePath = env["OCI_CONFIG_FILE"] ?? "\(NSHomeDirectory())/.oci/config"
          let ociProfileName = env["OCI_PROFILE"] ?? "DEFAULT"
          let regionId = try extractUserRegion(from: ociConfigFilePath, profile: ociProfileName)
          let region = Region.from(regionId: regionId ?? "") ?? .iad
          let signer = try APIKeySigner(configFilePath: ociConfigFilePath, configName: ociProfileName)
          self.client = try ObjectStorageClient(region: region, signer: signer)
        } catch {
          print("⚠️ Failed to initialize ObjectStorageClient: \(error)")
          return nil
        }
      }

  // MARK: - Gets namespace of the user's object storage
  func getNamespace() async throws {
    namespace = try await client.getNamespace()
  }

  // MARK: - Lists buckets in the user given compartment
  // TODO: Error handling is missing.
  func listBuckets() async throws {
    var compartmentId: String {
      UserDefaults.standard.string(forKey: "compartmentId") ?? ""
    }
    do {
      buckets =
        try await client
        .listBuckets(
          namespaceName:
            namespace,
          compartmentId: compartmentId
        )
    }
    catch {
      print(error.localizedDescription)
    }
  }

  // MARK: - Pusts object/file into the bucket
  // TODO: Possible errors are not handled at all. Force unwrapping.
  func putObject(filePath: String) async throws {
    isUploading = true
    defer { isUploading = false }

    let url = URL(fileURLWithPath: filePath)
    let fileData = try Data(contentsOf: url)
    try await client.putObject(
      namespaceName: namespace,
      bucketName: UserDefaults.standard.string(forKey: "selection")!,
      objectName: "\(url.lastPathComponent)",
      putObjectBody: fileData
    )

    self.showUploadSuccessMessage("Uploaded \(url.lastPathComponent) successfully")
  }

  // MARK: - Set and reset `uploadSuccessMessage`
  func showUploadSuccessMessage(_ text: String) {
    uploadSuccessMessage = text
    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
      self.uploadSuccessMessage = nil
    }
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
